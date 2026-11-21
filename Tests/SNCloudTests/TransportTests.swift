// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Synchronization
import Testing

// The production transport and its delegates, with a server under them.
//
// Everything else reaches the protocol through `ScriptedTransport`, which is the
// right seam for the protocol and the wrong one for this file: a double answers
// from a fixture and steps over every line that exists because the answer came
// off a socket — the ceiling that stops a body mid-flight, the progress
// reported as bytes arrive, the redirect the loading system follows on its own,
// the file a delegate has to claim before it returns. These run
// `SNURLSessionTransport`, `DownloadRouter`, `UploadSender` and
// `RedirectWatcher` themselves, over a `URLProtocol` answering from a script.
// No network.

// MARK: - Small requests

@Test("A body past the ceiling is refused rather than carried upwards")
func refusesABodyPastTheCeiling() async throws {
    let over = SNURLSessionTransport.bodyLimit + 1
    let url = ScriptedServer.expect(.init(chunks: [Data(count: over)]))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }
    await #expect(throws: SNError.oversizedResponse(bytes: over, limit: SNURLSessionTransport.bodyLimit)) {
        _ = try await SNURLSessionTransport(session: session).send(URLRequest(url: url))
    }
}

@Test("A reply that is not HTTP is refused rather than cast away")
func refusesAReplyThatIsNotHTTP() async throws {
    let url = ScriptedServer.expect(.init(isHTTP: false, chunks: [Data("a reply".utf8)]))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }
    await #expect(throws: SNError.malformedResponse("response is not HTTP")) {
        _ = try await SNURLSessionTransport(session: session).send(URLRequest(url: url))
    }
}

@Test("A cross-origin redirect of a GET loses the account's credentials on the way")
func stripsCredentialsOnARedirect() async throws {
    let target = ScriptedServer.expect(.init(chunks: [Data("ok".utf8)]), host: "storage.invalid")
    let start = ScriptedServer.expect(.init(redirectsTo: target), host: "viewer.invalid")
    let session = ScriptedServer.session(delegate: RedirectWatcher())
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: start)
    request.setValue("token", forHTTPHeaderField: "x-access-token")
    request.setValue("token_MACOSuuid_1", forHTTPHeaderField: "channel")
    request.setValue("XSRF-TOKEN=x", forHTTPHeaderField: "Cookie")

    let (data, _) = try await SNURLSessionTransport(session: session).send(request)

    #expect(data == Data("ok".utf8))
    let arrived = ScriptedServer.headers(target)
    #expect(arrived["x-access-token"] == nil)
    #expect(arrived["channel"] == nil)
    #expect(arrived["Cookie"] == nil)
}

@Test("A cross-origin redirect of a POST is not followed at all")
func refusesToCarryABodyAcrossOrigins() async throws {
    let target = ScriptedServer.expect(.init(chunks: [Data("ok".utf8)]), host: "elsewhere.invalid")
    let start = ScriptedServer.expect(.init(redirectsTo: target), host: "viewer.invalid")
    let session = ScriptedServer.session(delegate: RedirectWatcher())
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: start)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"password":"digest"}"#.utf8)

    let (_, response) = try await SNURLSessionTransport(session: session).send(request)

    #expect(response.statusCode == 302, "the redirect's own answer comes back")
    #expect(!ScriptedServer.reached(target), "the body was carried to another origin")
}

// MARK: - Downloads

@Suite("A download, over the delegate that carries it", .serialized)
struct DownloadDelegateTests {
    static let chunk = 64 << 10
    static let chunks = Array(repeating: Data(count: chunk), count: 8)
    static let bodyLength = Int64(chunk * 8)

    @Test("A download reports while it arrives and hands over a file that lives")
    func reportsAndHandsOverAFile() async throws {
        let url = ScriptedServer.expect(.init(chunks: Self.chunks))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }
        let reports = Mutex<[Int64]>([])

        let (file, response) = try await router.run(
            URLRequest(url: url),
            ceiling: DownloadCeiling(limitBytes: .max),
            onProgress: { done, _ in reports.withLock { $0.append(done) } },
            in: session
        )
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: file).count == Int(Self.bodyLength))
        #expect(reports.withLock { $0.count } > 1, "progress came in one lump at the end")
        #expect(reports.withLock { $0.last } == Self.bodyLength)
    }

    @Test("A declared length past the ceiling is refused before the body")
    func refusesADeclaredLength() async {
        let url = ScriptedServer.expect(.init(chunks: Self.chunks))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        await #expect(throws: SNError.oversizedResponse(bytes: Int(Self.bodyLength), limit: 1024)) {
            _ = try await router.run(
                URLRequest(url: url), ceiling: DownloadCeiling(limitBytes: 1024), onProgress: { _, _ in }, in: session
            )
        }
    }

    @Test("A body running past the ceiling without declaring it is stopped")
    func stopsAnUndeclaredOverrun() async {
        let url = ScriptedServer.expect(.init(declaresLength: false, chunks: Self.chunks, stallsUntilStopped: 2))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        await #expect(throws: SNError.self) {
            _ = try await router.run(
                URLRequest(url: url),
                ceiling: DownloadCeiling(limitBytes: Int64(Self.chunk) + 1),
                onProgress: { _, _ in },
                in: session
            )
        }
        #expect(await ScriptedServer.stops(url), "the refusal did not reach the wire")
        #expect(ScriptedServer.delivered(url) < Self.chunks.count)
    }

    @Test("A download the caller gave up on is taken off the wire")
    func cancelsOnTheWire() async {
        let url = ScriptedServer.expect(.init(parks: true))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let asking = Task {
            try await router.run(URLRequest(url: url), ceiling: DownloadCeiling(limitBytes: .max), onProgress: { _, _ in }, in: session)
        }
        await until("the request to reach the wire") { ScriptedServer.reached(url) }
        asking.cancel()
        #expect(await ScriptedServer.stops(url))
    }
}

@Test("The ceiling believes whichever of the two numbers is larger, and an undeclared length says nothing")
func ceilingRule() {
    let ceiling = DownloadCeiling(limitBytes: 100)
    #expect(ceiling.refusal(written: 50, expected: -1) == nil)
    #expect(ceiling.refusal(written: 100, expected: 100) == nil)
    #expect(ceiling.refusal(written: 10, expected: 101) == .oversizedResponse(bytes: 101, limit: 100))
    #expect(ceiling.refusal(written: 101, expected: 10) == .oversizedResponse(bytes: 101, limit: 100))
}

// MARK: - Uploads

@Test("A file goes up from disk, its progress reported, its answer read")
func uploadsFromDisk() async throws {
    let url = ScriptedServer.expect(.init(chunks: [Data(#"{"success":true}"#.utf8)]))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }
    let file = try ScratchFile.write(Data(count: 200_000))
    defer { try? FileManager.default.removeItem(at: file) }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"

    let (data, response) = try await SNURLSessionTransport(session: session).upload(request, fromFile: file) { _, _ in }

    #expect(response.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == #"{"success":true}"#)
    #expect(ScriptedServer.reached(url))
}

// MARK: - Waiting

/// Poll until `condition` holds, and fail the test — rather than hang the run —
/// if it does not within `seconds`.
func until(_ what: String, within seconds: TimeInterval = 10, _ condition: @Sendable () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out waiting for \(what)")
}

// MARK: - The server

/// A server answering from a script written before the request goes out: a
/// status, a body in as many pieces as the test wants, a length declared or
/// not, a redirect, a reply that is not HTTP. A copy of `rmcloud-swift`'s.
final class ScriptedServer: URLProtocol {
    struct Script: Sendable {
        var status = 200
        var isHTTP = true
        var redirectsTo: URL?
        var declaresLength = true
        var chunks: [Data] = []
        /// Never answer: the only way out is the caller giving up.
        var parks = false
        /// The pause between pieces, so a delegate's decision can arrive in time.
        var pace: TimeInterval = 0.005
        /// After this many pieces, wait for the stop instead of pacing on.
        var stallsUntilStopped: Int?
    }

    private struct Exchange {
        var script: Script
        var reached = false
        var delivered = 0
        var stopped = false
        var headers: [String: String] = [:]
    }

    private static let exchanges = Mutex<[String: Exchange]>([:])

    static func expect(_ script: Script, host: String = "server.invalid") -> URL {
        let url = URL.constant("https://\(host)/api/\(UUID().uuidString)")
        exchanges.withLock { $0[url.absoluteString] = Exchange(script: script) }
        return url
    }

    static func reached(_ url: URL) -> Bool {
        exchanges.withLock { $0[url.absoluteString]?.reached ?? false }
    }

    static func headers(_ url: URL) -> [String: String] {
        exchanges.withLock { $0[url.absoluteString]?.headers ?? [:] }
    }

    static func delivered(_ url: URL) -> Int {
        exchanges.withLock { $0[url.absoluteString]?.delivered ?? 0 }
    }

    static func stops(_ url: URL) async -> Bool {
        await until("the request to be called off") {
            exchanges.withLock { $0[url.absoluteString]?.stopped ?? false }
        }
        return exchanges.withLock { $0[url.absoluteString]?.stopped ?? false }
    }

    /// A session that goes nowhere but here.
    static func session(delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedServer.self]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let arrived = request.allHTTPHeaderFields ?? [:]
        guard let url = request.url,
              let script = Self.exchanges.withLock({ held -> Script? in
                  guard var exchange = held[url.absoluteString] else { return nil }
                  exchange.reached = true
                  exchange.headers = arrived
                  held[url.absoluteString] = exchange
                  return exchange.script
              })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard !script.parks else { return }
        if let target = script.redirectsTo {
            let response = HTTPURLResponse.fake(302, for: url, headers: ["Location": target.absoluteString])
            var following = URLRequest(url: target)
            following.httpMethod = request.httpMethod
            following.allHTTPHeaderFields = request.allHTTPHeaderFields
            following.httpBody = request.httpBody
            client?.urlProtocol(self, wasRedirectedTo: following, redirectResponse: response)
            // The 302 is a response in its own right: a delegate that declines
            // the hop is handed it as the answer, as from a real server, and a
            // load that finished without one traps in the loading system.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // Written from elsewhere: `stopLoading` arrives on this thread, and a
        // body handed over in one stretch could never be interrupted.
        nonisolated(unsafe) let me = self
        let client = self.client
        let key = url.absoluteString
        DispatchQueue.global().async {
            let length = script.chunks.reduce(0) { $0 + $1.count }
            let response: URLResponse = script.isHTTP
                ? HTTPURLResponse.fake(
                    script.status, for: url, headers: script.declaresLength ? ["Content-Length": String(length)] : [:]
                )
                : URLResponse(
                    url: url, mimeType: "application/octet-stream",
                    expectedContentLength: script.declaresLength ? length : -1, textEncodingName: nil
                )
            client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            for (index, chunk) in script.chunks.enumerated() {
                if index == script.stallsUntilStopped {
                    var patience = 1000
                    while patience > 0, Self.exchanges.withLock({ $0[key]?.stopped == false }) {
                        Thread.sleep(forTimeInterval: 0.005)
                        patience -= 1
                    }
                }
                guard Self.exchanges.withLock({ $0[key]?.stopped == false }) else { return }
                client?.urlProtocol(me, didLoad: chunk)
                Self.exchanges.withLock { $0[key]?.delivered += 1 }
                Thread.sleep(forTimeInterval: script.pace)
            }
            client?.urlProtocolDidFinishLoading(me)
        }
    }

    override func stopLoading() {
        guard let key = request.url?.absoluteString else { return }
        Self.exchanges.withLock { $0[key]?.stopped = true }
    }
}

@Test("JSON and upload replies are stopped mid-body without a declared length", arguments: [false, true])
func streamingBodyLimit(_ upload: Bool) async throws {
    let chunk = Data(count: 1024 * 1024)
    let url = ScriptedServer.expect(.init(
        declaresLength: false, chunks: Array(repeating: chunk, count: 40), stallsUntilStopped: 33
    ))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }
    let transport = SNURLSessionTransport(session: session)
    let file = try ScratchFile.write(Data("synthetic".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    var request = URLRequest(url: url)
    request.httpMethod = upload ? "PUT" : "GET"
    await #expect(throws: SNError.oversizedResponse(bytes: 33 * 1024 * 1024, limit: SNURLSessionTransport.bodyLimit)) {
        if upload {
            _ = try await transport.upload(request, fromFile: file) { _, _ in }
        } else {
            _ = try await transport.send(request)
        }
    }
    #expect(await ScriptedServer.stops(url))
    #expect(ScriptedServer.delivered(url) == 33)
}

@Test("Cancelling a JSON request or upload reply wakes its reader", arguments: [false, true])
func responseCancellation(_ upload: Bool) async throws {
    let url = ScriptedServer.expect(.init(parks: true))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }
    let file = try ScratchFile.write(Data("synthetic".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let reading = Task {
        let transport = SNURLSessionTransport(session: session)
        var request = URLRequest(url: url)
        request.httpMethod = upload ? "PUT" : "GET"
        if upload {
            return try await transport.upload(request, fromFile: file) { _, _ in }
        }
        return try await transport.send(request)
    }
    await until("the response request to arrive") { ScriptedServer.reached(url) }
    reading.cancel()
    do {
        _ = try await reading.value
        Issue.record("the cancelled response reader succeeded")
    } catch {
        #expect((error as? URLError)?.code == .cancelled)
    }
    #expect(await ScriptedServer.stops(url))
}
