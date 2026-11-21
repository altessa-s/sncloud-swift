// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Synchronization

// The doubles every suite here leans on: a scripted transport, a store of
// secrets that never touches a Keychain, a sleeper that does not sleep.

extension HTTPURLResponse {
    /// The answer a fake transport hands back. `HTTPURLResponse.init` is
    /// failable and never fails on what these suites hand it, so the unwrap is
    /// here, once, rather than a `!` at each call site.
    static func fake(
        _ status: Int = 200,
        for url: URL?,
        headers: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> HTTPURLResponse {
        guard let url, let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            preconditionFailure("no response for \(status)", file: file, line: line)
        }
        return response
    }
}

extension URL {
    static func constant(_ text: String, file: StaticString = #fileID, line: UInt = #line) -> URL {
        guard let url = URL(string: text) else {
            preconditionFailure("not a URL: \(text)", file: file, line: line)
        }
        return url
    }
}

/// A transport that answers from a prepared script and records the requests.
///
/// The XSRF handshake is answered on its own, outside the script, because
/// every suite that talks to the official cloud would otherwise open with the
/// same reply: `GET /api/csrf` gets the token in a header and a cookie beside
/// it. Everything else takes the next reply off the queue, and a queue that
/// has run dry answers 500 — a test that sends more than it scripted fails
/// loudly rather than hanging.
final class ScriptedTransport: SNTransporting {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = ""
        var headers: [String: String] = ["Content-Type": "application/json"]
        /// Bytes that are not text — an image from storage — in place of `body`.
        var bytes: Data?

        /// `{"success":true, …}` with the payload's fields beside it.
        static func ok(_ payload: String = "") -> Reply {
            let fields = payload.isEmpty ? "" : ",\(payload)"
            return Reply(body: #"{"success":true,"errorCode":null,"errorMsg":null\#(fields)}"#)
        }

        /// `{"success":false, "errorCode": code}` — with HTTP 200, as the
        /// service sends every refusal.
        static func refused(_ code: String, _ message: String = "refused") -> Reply {
            Reply(body: #"{"success":false,"errorCode":"\#(code)","errorMsg":"\#(message)"}"#)
        }
    }

    private let replies: Mutex<[Reply]>
    private let written = Mutex<[URL]>([])

    /// Every temporary file a download wrote, so that a test can ask which of
    /// them are still there.
    var downloadedFiles: [URL] { written.withLock { $0 } }
    private let recorded = Mutex<[URLRequest]>([])
    private let xsrfTokens: Mutex<[String]>

    /// `xsrf` lists the tokens successive handshakes hand out; the last one
    /// repeats.
    init(_ replies: [Reply], xsrf: [String] = ["xsrf-1"]) {
        self.replies = Mutex(replies)
        self.xsrfTokens = Mutex(xsrf)
    }

    /// Every request, the handshakes included.
    var requests: [URLRequest] { recorded.withLock { $0 } }

    /// The requests that were not the XSRF handshake.
    var calls: [URLRequest] { requests.filter { $0.url?.path != "/api/csrf" } }

    var handshakes: Int { requests.count - calls.count }

    func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let file = try ScratchFile.write(data)
        written.withLock { $0.append(file) }
        onProgress(Int64(data.count), Int64(data.count))
        return (file, response)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        if request.url?.path == "/api/csrf" {
            let token = xsrfTokens.withLock { queue -> String in
                queue.count > 1 ? queue.removeFirst() : (queue.first ?? "xsrf")
            }
            let headers = [
                "X-XSRF-TOKEN": token,
                "Set-Cookie": "XSRF-TOKEN=\(token); Path=/",
            ]
            return (Data(), .fake(for: request.url, headers: headers))
        }
        let reply = replies.withLock { queue -> Reply in
            queue.isEmpty ? Reply(status: 500) : queue.removeFirst()
        }
        return (reply.bytes ?? Data(reply.body.utf8), .fake(reply.status, for: request.url, headers: reply.headers))
    }
}

extension URLRequest {
    /// The JSON body this request carried, as an object to ask questions of.
    var jsonBody: [String: Any] {
        guard let body = httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [:] }
        return object
    }
}

/// The secrets, doubled. A real store writes into the Keychain of whoever runs
/// the tests, and what it would write there are tokens.
final class InMemorySecrets: SNSecretStoring {
    private let storage = Mutex<[SNSecret: String]>([:])

    init(_ initial: [SNSecret: String] = [:]) {
        storage.withLock { $0 = initial }
    }

    func secret(_ which: SNSecret) throws -> String? {
        storage.withLock { $0[which] }
    }

    func keep(_ value: String, as which: SNSecret) throws {
        storage.withLock { $0[which] = value }
    }

    func discard(_ which: SNSecret) throws {
        storage.withLock { $0[which] = nil }
    }
}

/// A sleeper that waits for nothing but remembers how long it was asked for.
final class RecordingSleeper: SNSleeping {
    private let recorded = Mutex<[Duration]>([])

    var delays: [Duration] { recorded.withLock { $0 } }

    func sleep(for duration: Duration) async throws {
        recorded.withLock { $0.append(duration) }
    }
}

/// A JWT with the claims given, unsigned: nothing here checks a signature.
func syntheticToken(claims: String) -> String {
    func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(#"{"alg":"HS256","typ":"JWT"}"#)).\(encode(claims)).signature"
}

/// A token that lives until 2100.
let liveToken = syntheticToken(claims: #"{"userId":"1","exp":4102444800}"#)

/// A session and a client on the official cloud, logged in with `liveToken`.
func loggedInClient(
    _ transport: ScriptedTransport,
    endpoints: SNEndpoints = .official,
    secrets: InMemorySecrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com"]),
    sleeper: RecordingSleeper = RecordingSleeper()
) -> (SNClient, SNSession, InMemorySecrets) {
    let session = SNSession(endpoints: endpoints, transport: transport, secrets: secrets, sleeper: sleeper)
    return (SNClient(session: session), session, secrets)
}
