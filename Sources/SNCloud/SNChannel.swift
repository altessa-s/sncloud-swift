// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// What every call to `/api` is made of: a JSON body, the browser state the
/// official cloud insists on, the envelope every answer comes in, and a retry
/// that knows what is worth repeating.
///
/// Shared by the session, which logs in through it, and the client, which does
/// everything else — because the XSRF token and the cookies it pairs with are
/// one state, and a login that fetched them is what the first listing after it
/// has to present.
final class SNChannel: Sendable {
    let endpoints: SNEndpoints
    let transport: any SNTransporting
    let policy: SNRetryPolicy
    let sleeper: any SNSleeping
    let browser = BrowserState()

    init(
        endpoints: SNEndpoints,
        transport: any SNTransporting,
        policy: SNRetryPolicy,
        sleeper: any SNSleeping
    ) {
        self.endpoints = endpoints
        self.transport = transport
        self.policy = policy
        self.sleeper = sleeper
    }

    /// One call: POST `body` to `/api/<path>`, and the payload it answered with.
    ///
    /// `changes` says whether the call alters the account. A listing that met a
    /// 5xx is asked again; a move that met one is not — see
    /// `SNRetryPolicy.shouldRetryChange` for why.
    func call<Payload: Decodable & Sendable>(
        _ path: String,
        on api: SNAPI = .app,
        method: String = "POST",
        body: some Encodable & Sendable,
        token: String?,
        headers: [String: String] = [:],
        changes: Bool,
        timeout: TimeInterval? = nil,
        epoch fixed: Int? = nil,
        as payload: Payload.Type = Payload.self
    ) async throws -> Payload {
        let data = body is NoBody ? nil : try JSONEncoder().encode(body)
        let url = api == .web ? endpoints.web(path) : endpoints.app(path)
        var request = SNRequest.json(url, method: method, body: data)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let timeout { request.timeoutInterval = timeout }

        // The whole call — every retry, every second chance on a 403 — belongs
        // to the conversation it started in. A logout in the middle ends it
        // rather than letting it carry on in the next one.
        // A login attempt names its own — the one its reset began — so that an
        // attempt overtaken at any suspension cannot pick up the next one's.
        let current = await browser.epoch
        let epoch = fixed ?? current
        do {
            return try await withRetry(
                policy: policy,
                sleeper: sleeper,
                retrying: changes ? policy.shouldRetryChange : policy.shouldRetry
            ) {
                let answer = try await exchange(request, token: token, epoch: epoch, api: api)
                return try Self.open(answer, as: Payload.self)
            }
        } catch let error as SNError {
            // The path and the reason are not secrets, unlike the headers and
            // the body.
            Log.supernote.error("call failed: \(path, .public) — \(String(describing: error), .public)")
            throw error
        }
    }

    /// The same, for a call whose answer is the envelope and nothing else.
    func call(
        _ path: String,
        on api: SNAPI = .app,
        body: some Encodable & Sendable,
        token: String?,
        headers: [String: String] = [:],
        changes: Bool,
        epoch fixed: Int? = nil
    ) async throws {
        _ = try await call(
            path, on: api, body: body, token: token, headers: headers, changes: changes, epoch: fixed, as: Nothing.self
        )
    }

    /// One request with the browser state on it, and one second chance on a
    /// 403 with a fresh XSRF token.
    ///
    /// The service rotates the token — after a code is verified, at least — and
    /// a stale one is refused with a 403 that says nothing about the access
    /// token. One fetch mends that; a second 403 is about something else and is
    /// reported as it came.
    private func exchange(_ request: URLRequest, token: String?, epoch: Int, api: SNAPI) async throws -> Data {
        let xsrf = api == .web && endpoints.webUsesXSRF
        var request = request
        if let token {
            request.setValue(token, forHTTPHeaderField: SNRequest.accessTokenHeader)
        }
        var refreshed = false
        while true {
            let prepared = try await browser.prepare(request, channel: self, api: api, epoch: epoch)
            let (data, response) = try await transport.send(prepared)
            // The jar is the web page's: an answer from the apps' host has no
            // business in it, and the jar does not keep a cookie's origin, so
            // one kept from there would go to the web host next.
            if api == .web { await browser.absorb(response, epoch: epoch) }
            // An answer that arrives after its conversation ended is not
            // handed on: whoever ended it has said what they think of it.
            guard await browser.epoch == epoch else { throw SNError.notLoggedIn }
            if response.statusCode == 403, xsrf, !refreshed {
                refreshed = true
                await browser.forgetXSRF(epoch: epoch)
                continue
            }
            if let refusal = SNError.fromHTTP(response) { throw Self.explained(refusal, by: data) }
            return data
        }
    }

    /// A refusal by status, outranked by the envelope where the body has one
    /// with a code in it: at least one server answers a held sync lock with
    /// 409 *and* `E0078`, and the code is the one that says what happened.
    ///
    /// A 4xx only. A 429 keeps its own reading — it carries the wait — and a
    /// 5xx keeps its own because it is the one the retry policy repeats: a
    /// code beside it would turn a server's bad moment into a final answer.
    static func explained(_ refusal: SNError, by body: Data) -> SNError {
        guard case .http(let status, _) = refusal, (400..<500).contains(status) else { return refusal }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              let code = envelope.errorCode, !code.trimmingCharacters(in: .whitespaces).isEmpty,
              envelope.success?.value != true
        else { return refusal }
        return SNError.fromEnvelope(code: code, message: envelope.errorMsg)
    }

    /// The XSRF handshake: a GET whose answer names the token in a header — or,
    /// failing that, in the cookie it also sets.
    func fetchXSRF(epoch: Int) async throws -> String {
        let url = endpoints.csrf
        return try await withRetry(policy: policy, sleeper: sleeper, retrying: policy.shouldRetry) {
            // Every attempt, the retries included, checks its conversation is
            // still the current one before it borrows the jar.
            var request = SNRequest.to(url)
            if let cookie = try await browser.cookieHeader(epoch: epoch) {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            let (_, response) = try await transport.send(request)
            await browser.absorb(response, epoch: epoch)
            guard await browser.epoch == epoch else { throw SNError.notLoggedIn }
            if let refusal = SNError.fromHTTP(response) { throw refusal }
            if let token = response.value(forHTTPHeaderField: SNRequest.xsrfHeader), !token.isEmpty {
                return token
            }
            if let token = await browser.cookie(SNRequest.xsrfCookie) { return token }
            throw SNError.malformedResponse("the XSRF handshake named no token")
        }
    }

    /// The envelope opened: the payload when it says `success`, the service's
    /// own refusal when it does not.
    static func open<Payload: Decodable>(_ data: Data, as payload: Payload.Type) throws -> Payload {
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            // Described, not quoted: a body that is not the envelope may still
            // be an answer to a login, and this message reaches the log.
            throw SNError.malformedResponse("not the service's JSON: \(SNError.shape(of: data))")
        }
        let code = envelope.errorCode?.trimmingCharacters(in: .whitespaces) ?? ""
        // `success` is the answer; a missing one is read as success only where
        // nothing says otherwise, because one private-cloud answer omits it.
        let succeeded = envelope.success?.value ?? code.isEmpty
        guard succeeded else {
            throw SNError.fromEnvelope(code: envelope.errorCode, message: envelope.errorMsg)
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            throw SNError.malformedResponse("\(Payload.self): \(error)")
        }
    }

    private struct Envelope: Decodable {
        let success: WireFlag?
        let errorCode: String?
        let errorMsg: String?
    }

    /// A payload with nothing in it beyond the envelope.
    struct Nothing: Decodable {}
}

/// Which of the official cloud's two hosts a call goes to. See `SNEndpoints`.
enum SNAPI: Sendable, Equatable {
    /// The apps' host: the login, the device API, the uploads.
    case app
    /// The web page's host: the listing by identifier, behind the XSRF handshake.
    case web
}

/// A body with nothing in it: `{}`.
struct EmptyBody: Encodable {}

/// No body at all — not even `{}` — for a GET, and for a DELETE that names
/// what it deletes in its path.
struct NoBody: Encodable {}

extension SNError {
    /// What a body that was not what it should have been looks like — its
    /// length and what kind of document it opens as — without a word of what
    /// it says. HTML from a captive portal and XML from storage are told apart,
    /// and a token in a mangled answer stays out of the error.
    static func shape(of data: Data) -> String {
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = switch head.first {
        case "<": head.lowercased().contains("html") ? "HTML" : "XML"
        case "{", "[": "JSON of another shape"
        case nil: "empty"
        default: "text"
        }
        return "\(kind), \(data.count) bytes"
    }
}

/// The part of a browser the official cloud insists on: its cookies and the
/// XSRF token that has to agree with one of them.
///
/// An actor of its own, because the client runs calls side by side and the
/// first several of them would otherwise each fetch a token of their own.
actor BrowserState {
    private var cookies: [String: String] = [:]
    private var xsrf: String?
    private var fetching: (epoch: Int, task: Task<String, any Error>)?

    /// Which conversation the state belongs to. Moved by `forgetAll`, so that
    /// a request — or a handshake — that set out before a logout cannot put
    /// its cookies back into the jar the logout just emptied: they arrive
    /// stamped with the epoch they left in, and a stale stamp is dropped.
    private(set) var epoch = 0

    /// `request` with the cookies on it and, where the server wants one, the
    /// XSRF token — fetched first if there is none yet — for a call that
    /// started in `epoch`. A call whose conversation has ended since is told
    /// so rather than handed the next conversation's cookies: checked before,
    /// and again after the fetch it may have waited on.
    ///
    /// The jar goes to the web host only. The apps' host is not sent cookies by
    /// the official client, and the web page's conversation is no business of
    /// the device API's.
    func prepare(_ request: URLRequest, channel: SNChannel, api: SNAPI, epoch stamp: Int) async throws -> URLRequest {
        guard stamp == epoch else { throw SNError.notLoggedIn }
        var request = request
        guard api == .web else { return request }
        if channel.endpoints.webUsesXSRF {
            request.setValue(try await token(using: channel), forHTTPHeaderField: SNRequest.xsrfHeader)
            guard stamp == epoch else { throw SNError.notLoggedIn }
        }
        if let cookie = cookieHeader {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// The token in hand, or the one being fetched, or a new fetch. One fetch
    /// however many callers want it, and one answer for all of them: what the
    /// state holds once the fetch is in, which is the rotated cookie where the
    /// handshake set one — the half the server compares against.
    private func token(using channel: SNChannel) async throws -> String {
        if let xsrf { return xsrf }
        let started = epoch
        let task: Task<String, any Error>
        if let fetching, fetching.epoch == started {
            task = fetching.task
        } else {
            task = Task { try await channel.fetchXSRF(epoch: started) }
            fetching = (started, task)
        }
        let fetched: String
        do {
            fetched = try await task.value
        } catch {
            if fetching?.epoch == started, fetching?.task == task { fetching = nil }
            throw error
        }
        if fetching?.epoch == started, fetching?.task == task { fetching = nil }
        // Kept only for the conversation it was fetched in. A caller from
        // before a logout still gets a token to finish its request with; the
        // state does not.
        guard started == epoch else { return fetched }
        if xsrf == nil { xsrf = fetched }
        return xsrf ?? fetched
    }

    /// Keep what a response set, if it belongs to the current conversation.
    /// The XSRF cookie, when it moves, moves the token with it — that is how
    /// the service rotates it.
    func absorb(_ response: HTTPURLResponse, epoch stamp: Int) {
        guard stamp == epoch, let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, field in
            fields[String(describing: field.key)] = String(describing: field.value)
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            if let expires = cookie.expiresDate, expires < Date() {
                cookies[cookie.name] = nil
            } else {
                cookies[cookie.name] = cookie.value
            }
            if cookie.name == SNRequest.xsrfCookie, !cookie.value.isEmpty {
                xsrf = cookie.value
            }
        }
    }

    func forgetXSRF(epoch stamp: Int) {
        guard stamp == epoch else { return }
        xsrf = nil
        cookies[SNRequest.xsrfCookie] = nil
    }

    /// Everything: a logout leaves nothing of the conversation behind.
    /// Answers the epoch the new conversation has, in the same step that
    /// begins it — a caller that read it afterwards could read a later one.
    @discardableResult
    func forgetAll() -> Int {
        epoch += 1
        cookies = [:]
        xsrf = nil
        fetching = nil
        return epoch
    }

    func cookie(_ name: String) -> String? { cookies[name] }

    /// The `Cookie` header for a request of conversation `stamp`, or why it
    /// may have none: the conversation has ended.
    func cookieHeader(epoch stamp: Int) throws -> String? {
        guard stamp == epoch else { throw SNError.notLoggedIn }
        return cookieHeader
    }

    /// The `Cookie` header, sorted so that the same jar always says the same
    /// thing.
    var cookieHeader: String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}
