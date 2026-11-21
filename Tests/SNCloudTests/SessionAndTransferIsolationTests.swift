// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Synchronization
@testable import SNCloud
import Testing

// MARK: - Credentials in the wire log

@Test("A logged JSON body has its signatures, tokens and signed URLs redacted")
func redactsLoggedBodies() throws {
    let body = #"""
    {"success":true,"url":"https://bucket.s3.amazonaws.com/u/abc.pdf?X-Amz-Signature=secret",
     "s3Authorization":"AWS4-HMAC-SHA256 Credential=key","xamzDate":"20261003T000000Z",
     "token":"jwt","validCodeKey":"k","fileName":"Paper.pdf"}
    """#
    let text = try #require(SNWireLog.bodyText(Data(body.utf8), contentType: "application/json", level: .bodies))
    #expect(!text.contains("secret"))
    #expect(!text.contains("Credential=key"))
    #expect(!text.contains("jwt"))
    #expect(text.contains(#""validCodeKey":"<redacted>""#))
    #expect(text.contains("Paper.pdf"), "a file name is the point of the level")
    #expect(text.contains("https://bucket.s3.amazonaws.com/u/abc.pdf (+1 query items)"))
}

@Test("An error about an unreadable answer describes it without quoting it")
func describesWithoutQuoting() {
    #expect(SNError.shape(of: Data(#"{"token":"jwt"#.utf8)) == "JSON of another shape, 13 bytes")
    #expect(SNError.shape(of: Data()) == "empty, 0 bytes")
}

@Test("A Location header to signed storage loses its query in the log")
func sanitisesLocation() {
    let line = SNWireLog.headerLine(field: "Location", value: "https://s3.example.com/o?X-Amz-Signature=s", arrow: "←")
    #expect(!"\(line)".contains("Signature=s"))
}

// MARK: - Redirects

@Test("A redirect that would carry a body off its origin is refused, not stripped")
func refusesABodyLeavingItsOrigin() {
    var post = URLRequest(url: .constant("https://elsewhere.example.com/api/official/user/account/login/new"))
    post.httpMethod = "POST"
    post.httpBody = Data(#"{"password":"digest"}"#.utf8)
    #expect(Redirects.following(post, from: .constant("https://cloud.supernote.com/api/official/user/account/login/new")) == nil)

    // Inside the origin it is still the same conversation.
    var home = post
    home.url = .constant("https://cloud.supernote.com/api/other")
    #expect(Redirects.following(home, from: .constant("https://cloud.supernote.com/api/x")) != nil)

    // A GET for bytes may hop to storage, without its credentials.
    var get = URLRequest(url: .constant("https://storage.example.com/obj"))
    get.setValue("t", forHTTPHeaderField: "x-access-token")
    let hop = Redirects.following(get, from: .constant("https://cloud.supernote.com/api/x"))
    #expect(hop != nil)
    #expect(hop?.value(forHTTPHeaderField: "x-access-token") == nil)
}

@Test("A redirect from HTTPS to plain HTTP is refused")
func refusesADowngrade() {
    let get = URLRequest(url: .constant("http://cloud.supernote.com/api/x"))
    #expect(Redirects.following(get, from: .constant("https://cloud.supernote.com/api/x")) == nil)
}

// MARK: - Logins that were overtaken

/// A transport that holds the first request on one path until it is let
/// through, and answers everything from a script.
///
/// The arrival and whoever waits for it are one state under one lock: kept
/// apart, a waiter could read "not yet", the request arrive and find nobody,
/// and the waiter then wait for ever.
final class HeldTransport: SNTransporting {
    private enum Arrival {
        case notYet
        case awaited(CheckedContinuation<Void, Never>)
        case arrived
    }

    private let script: ScriptedTransport
    private let heldPath: String
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let arrival = Mutex(Arrival.notYet)
    /// Only the first request on the path is held; the rest go straight on.
    private let alreadyHeld = Mutex(false)

    init(_ script: ScriptedTransport, holding path: String) {
        self.script = script
        self.heldPath = path
    }

    func waitForHeldRequest() async {
        await withCheckedContinuation { continuation in
            let already = arrival.withLock { state -> Bool in
                if case .arrived = state { return true }
                state = .awaited(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    func letThrough() {
        let held = gate.withLock { held -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        held?.resume()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let hold = request.url?.path == heldPath && alreadyHeld.withLock { held in
            defer { held = true }
            return !held
        }
        if hold {
            await withCheckedContinuation { continuation in
                gate.withLock { $0 = continuation }
                let waiter = arrival.withLock { state -> CheckedContinuation<Void, Never>? in
                    defer { state = .arrived }
                    if case .awaited(let waiter) = state { return waiter }
                    return nil
                }
                waiter?.resume()
            }
        }
        return try await script.send(request)
    }
}

@Test("A code that arrives after the session was forgotten does not bring the login back")
func doesNotReviveAForgottenLogin() async throws {
    let script = ScriptedTransport([
        .ok(#""randomCode":"r","timestamp":1"#),
        .refused("E1760"),
        .ok(#""validCodeKey":"k""#),
    ])
    let transport = HeldTransport(script, holding: "/api/user/mail/validcode")
    let secrets = InMemorySecrets()
    let session = SNSession(transport: transport, secrets: secrets)
    _ = try await session.logIn(account: "user@example.com", password: "pw")

    let sending = Task { try await session.sendVerificationCode() }
    await transport.waitForHeldRequest()
    try await session.forget()
    transport.letThrough()

    await #expect(throws: SNError.noVerificationPending) { try await sending.value }
    await #expect(throws: SNError.noVerificationPending) { try await session.verify(code: "123456") }
    #expect(try secrets.secret(.accessToken) == nil)
}

@Test("An older login that finishes last does not overwrite the newer one")
func keepsTheNewerLogin() async throws {
    let older = syntheticToken(claims: #"{"exp":4102444800,"who":"older"}"#)
    // Replies go out in the order requests reach the script: the first login's
    // challenge, the second's challenge, the second's login, and — once it is
    // let through — the first's.
    let script = ScriptedTransport([
        .ok(#""randomCode":"r","timestamp":1"#),
        .ok(#""randomCode":"r","timestamp":2"#),
        .ok(#""token":"\#(liveToken)""#),
        .ok(#""token":"\#(older)""#),
    ])
    let transport = HeldTransport(script, holding: "/api/official/user/account/login/new")
    let secrets = InMemorySecrets()
    let session = SNSession(transport: transport, secrets: secrets)

    let overtaken = Task { try await session.logIn(account: "old@example.com", password: "pw") }
    await transport.waitForHeldRequest()
    #expect(try await session.logIn(account: "new@example.com", password: "pw") == .loggedIn)
    transport.letThrough()

    await #expect(throws: SNError.notLoggedIn) { _ = try await overtaken.value }
    #expect(try secrets.secret(.account) == "new@example.com", "the overtaken login overwrote the newer one")
    #expect(try secrets.secret(.accessToken) == liveToken)
}

// MARK: - The sync lock

@Test("A second lock scope on the same client is refused while the first runs")
func refusesAnOverlappingLock() async throws {
    let script = ScriptedTransport([.ok(#""synType":true"#), .ok()])
    let transport = HeldTransport(script, holding: "/api/file/2/files/synchronous/end")
    let session = SNSession(
        transport: transport,
        secrets: InMemorySecrets([.accessToken: liveToken]),
        sleeper: RecordingSleeper()
    )
    let client = SNDeviceClient(session: session)

    let first = Task { try await client.withSyncLock { _ in () } }
    await transport.waitForHeldRequest()
    await #expect(throws: SNError.syncLocked) { try await client.withSyncLock { _ in () } }
    transport.letThrough()
    try await first.value
}

// MARK: - Ranges

@Test("A server that ignores the range is not taken to have served it")
func refusesAnIgnoredRange() async throws {
    let link = #""url":"http://nas.local/api/oss/download?s=1","content_hash":"5b5778d47e5d7cc586801850e65f0d0b","size":15"#
    let transport = ScriptedTransport([
        .ok(link),
        .init(status: 200, body: "hello supernote", headers: ["Content-Type": "application/octet-stream"]),
    ])
    let session = SNSession(transport: transport, secrets: InMemorySecrets([.accessToken: liveToken]), sleeper: RecordingSleeper())
    let client = SNDeviceClient(session: session)
    await #expect(throws: SNError.malformedResponse("asked for bytes 5...9, answered 200 instead of 206")) {
        _ = try await client.download(SNFileID(rawValue: 1), range: 5...9)
    }
    await #expect(throws: SNError.self) { _ = try await client.download(SNFileID(rawValue: 1), range: -1...4) }
}

// MARK: - Multipart

@Test("The form's progress counts the file's bytes, not its framing")
func countsOnlyTheFile() throws {
    let source = try ScratchFile.write(Data("hello supernote".utf8))
    defer { try? FileManager.default.removeItem(at: source) }
    let form = try MultipartFile.write(from: source, length: 15, name: "a.txt", boundary: "B")
    defer { try? FileManager.default.removeItem(at: form.url) }
    let body = try Data(contentsOf: form.url)
    #expect(body.subdata(in: Int(form.headerLength)..<Int(form.headerLength) + 15) == Data("hello supernote".utf8))
}

@Test("A form that cannot be finished leaves no file behind")
func cleansUpAFailedForm() throws {
    let source = try ScratchFile.write(Data("short".utf8))
    defer { try? FileManager.default.removeItem(at: source) }
    // A directory of this test's own: the shared one is written into by the
    // suites running beside it.
    let own = FileManager.default.temporaryDirectory.appending(path: "form-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: own) }
    ScratchFile.$directory.withValue(own) {
        #expect(throws: SNError.self) {
            _ = try MultipartFile.write(from: source, length: 999, name: "a.txt")
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: own.path).isEmpty, "a partial form was left in the temporary directory")
}

// MARK: - Second pass

@Test("A login overtaken while its salt was on the way never sends the password digest")
func dropsAnOvertakenLoginBeforeItSends() async throws {
    let script = ScriptedTransport([.ok(#""randomCode":"r","timestamp":1"#)])
    let transport = HeldTransport(script, holding: "/api/official/user/query/random/code")
    let session = SNSession(transport: transport, secrets: InMemorySecrets())

    let login = Task { try await session.logIn(account: "user@example.com", password: "pw") }
    await transport.waitForHeldRequest()
    try await session.forget()
    transport.letThrough()

    await #expect(throws: SNError.notLoggedIn) { _ = try await login.value }
    #expect(!script.calls.contains { $0.url?.path == "/api/official/user/account/login/new" })
}

@Test("A call from before a logout is not handed the next conversation's state")
func endsACallFromAnEndedConversation() async throws {
    let browser = BrowserState()
    let channel = SNChannel(
        endpoints: .privateCloud(.constant("http://nas.local")),
        transport: ScriptedTransport([]),
        policy: .default,
        sleeper: RecordingSleeper()
    )
    let before = await browser.epoch
    await browser.forgetAll()
    await #expect(throws: SNError.notLoggedIn) {
        _ = try await browser.prepare(URLRequest(url: .constant("http://nas.local/api/x")), channel: channel, api: .web, epoch: before)
    }
    // And its answer's cookies are not kept.
    await browser.absorb(.fake(for: .constant("http://nas.local/api/x"), headers: ["Set-Cookie": "SESSION=old; Path=/"]), epoch: before)
    #expect(await browser.cookie("SESSION") == nil)
}

@Test("Two clients on one session with one name cannot both hold the lock")
func sharesTheLockClaimAcrossClients() async throws {
    let script = ScriptedTransport([.ok(#""synType":true"#), .ok(), .ok(#""synType":true"#), .ok()])
    let transport = HeldTransport(script, holding: "/api/file/2/files/synchronous/end")
    let session = SNSession(transport: transport, secrets: InMemorySecrets([.accessToken: liveToken]), sleeper: RecordingSleeper())
    let first = SNDeviceClient(session: session)
    let second = SNDeviceClient(session: session)

    let running = Task { try await first.withSyncLock { _ in () } }
    await transport.waitForHeldRequest()
    await #expect(throws: SNError.syncLocked) { try await second.withSyncLock { _ in () } }
    transport.letThrough()
    try await running.value

    // Once it is let go, the name is free again — at once, not after a task.
    try await second.withSyncLock { _ in () }
}

@Test("A range is held to its Content-Range, and to the bytes that came")
func holdsARangeToItsHeader() async throws {
    let link = ScriptedTransport.Reply.ok(#""url":"http://nas.local/o?s=1","content_hash":"aa","size":15"#)
    func answer(_ body: String, range: String?) -> ScriptedTransport.Reply {
        var headers = ["Content-Type": "application/octet-stream"]
        if let range { headers["Content-Range"] = range }
        return .init(status: 206, body: body, headers: headers)
    }
    let cases: [(ScriptedTransport.Reply, Bool)] = [
        (answer("lo su", range: "bytes 3-7/15"), true),
        (answer("lo su", range: nil), false),                       // no header
        (answer("lo su", range: "bytes 3-garbage"), false),         // does not parse
        (answer("l", range: "bytes 3-7/15"), false),                // truncated body
        (answer("lo su", range: "bytes 4-8/15"), false),            // wrong start
        (answer("ote", range: "bytes 12-14/15"), true),             // short, but at the end of the file
    ]
    for (index, (reply, accepted)) in cases.enumerated() {
        let transport = ScriptedTransport([link, reply])
        let session = SNSession(transport: transport, secrets: InMemorySecrets([.accessToken: liveToken]), sleeper: RecordingSleeper())
        let client = SNDeviceClient(session: session)
        let range: ClosedRange<Int64> = index == 5 ? 12...20 : 3...7
        do {
            let file = try await client.download(SNFileID(rawValue: 1), range: range)
            try? FileManager.default.removeItem(at: file)
            #expect(accepted, "case \(index) was accepted")
        } catch {
            #expect(!accepted, "case \(index) was refused: \(error)")
        }
    }
}

@Test("A long logged body is cut without losing the cap, even through a multi-byte character")
func cutsALongBodySafely() throws {
    let name = String(repeating: "\u{0436}", count: SNWireLog.bodyLimit)
    let body = Data(#"{"fileName":"\#(name)"}"#.utf8)
    let text = try #require(SNWireLog.bodyText(body, contentType: "application/json", level: .bodies))
    #expect(text.utf8.count < SNWireLog.bodyLimit + 64)
    #expect(text.contains("bytes in all"))
}

// MARK: - Third pass

@Test("An overtaken login's cookies do not replace the newer login's")
func isolatesTheCookiesOfAnOvertakenLogin() async throws {
    var older = ScriptedTransport.Reply.ok(#""token":"\#(syntheticToken(claims: #"{"exp":4102444800}"#))""#)
    older.headers["Set-Cookie"] = "SESSION=A; Path=/"
    var newer = ScriptedTransport.Reply.ok(#""token":"\#(liveToken)""#)
    newer.headers["Set-Cookie"] = "SESSION=B; Path=/"
    let script = ScriptedTransport([
        .ok(#""randomCode":"r","timestamp":1"#),
        .ok(#""randomCode":"r","timestamp":2"#),
        newer,
        older,
    ])
    let transport = HeldTransport(script, holding: "/api/official/user/account/login/new")
    let session = SNSession(transport: transport, secrets: InMemorySecrets())

    let overtaken = Task { try await session.logIn(account: "old@example.com", password: "pw") }
    await transport.waitForHeldRequest()
    _ = try await session.logIn(account: "new@example.com", password: "pw")
    transport.letThrough()
    await #expect(throws: SNError.notLoggedIn) { _ = try await overtaken.value }

    // The apps' host never fills the web page's jar: neither login's cookie
    // is kept, the overtaken one least of all.
    #expect(await session.channel.browser.cookie("SESSION") == nil)
}

@Test("A handshake retried after a logout does not borrow the next conversation's cookies")
func endsAHandshakeFromAnEndedConversation() async throws {
    let browser = BrowserState()
    let stale = await browser.epoch
    await browser.forgetAll()
    await browser.absorb(.fake(for: .constant("https://cloud.supernote.com/api/csrf"), headers: ["Set-Cookie": "SESSION=new; Path=/"]), epoch: await browser.epoch)
    await #expect(throws: SNError.notLoggedIn) { _ = try await browser.cookieHeader(epoch: stale) }
}

// MARK: - Fourth pass

@Test("A login overtaken while it was still resetting carries no cookies into the newer one")
func pinsEachLoginToItsOwnConversation() async throws {
    // The first login is overtaken before its salt comes back; the answer to
    // its challenge sets a cookie, which must not land in the second login's
    // conversation.
    var challengeA = ScriptedTransport.Reply.ok(#""randomCode":"r","timestamp":1"#)
    challengeA.headers["Set-Cookie"] = "SESSION=A; Path=/"
    var loginB = ScriptedTransport.Reply.ok(#""token":"\#(liveToken)""#)
    loginB.headers["Set-Cookie"] = "SESSION=B; Path=/"
    let script = ScriptedTransport([
        .ok(#""randomCode":"r","timestamp":2"#),
        loginB,
        challengeA,
    ])
    let transport = HeldTransport(script, holding: "/api/official/user/query/random/code")
    let session = SNSession(transport: transport, secrets: InMemorySecrets())

    let overtaken = Task { try await session.logIn(account: "old@example.com", password: "pw") }
    await transport.waitForHeldRequest()
    _ = try await session.logIn(account: "new@example.com", password: "pw")
    transport.letThrough()
    await #expect(throws: SNError.notLoggedIn) { _ = try await overtaken.value }

    // The apps' host never fills the web page's jar: neither login's cookie
    // is kept, the overtaken one least of all.
    #expect(await session.channel.browser.cookie("SESSION") == nil)
}

@Test("A Retry-After the server wrote as infinity or a century is held to the ceiling, not a crash")
func clampsAnAbsurdRetryAfter() {
    let policy = SNRetryPolicy.default
    // Not a number a wait can be made of: ignored, and the formula used.
    #expect(policy.delay(beforeAttempt: 2, retryAfter: .infinity) <= policy.maxDelay)
    #expect(policy.delay(beforeAttempt: 2, retryAfter: 1e300) == policy.maxDelay)
    #expect(policy.delay(beforeAttempt: 60, retryAfter: nil) <= policy.maxDelay)
    let response = HTTPURLResponse.fake(429, for: .constant("https://viewer.supernote.com/api/x"), headers: ["Retry-After": "inf"])
    #expect(SNError.fromHTTP(response) == .rateLimited(retryAfter: nil))
}

@Test("A failed request is logged by its error's domain and code, never its URL")
func logsAFailureWithoutItsURL() {
    let signed = URL.constant("https://bucket.s3.amazonaws.com/o?X-Amz-Signature=secret")
    let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: signed, NSURLErrorFailingURLStringErrorKey: signed.absoluteString])
    let text = SNWireLog.failure(error)
    #expect(!text.contains("secret"))
    #expect(text.contains(NSURLErrorDomain))
}

@Test("A logout that comes back after a new login leaves that login alone")
func keepsALoginMadeDuringLogout() async throws {
    // The logout is held, so the login's two calls reach the script first.
    let script = ScriptedTransport([
        .ok(#""randomCode":"r","timestamp":1"#),
        .ok(#""token":"\#(liveToken)""#),
        .ok(),
    ])
    let transport = HeldTransport(script, holding: "/api/user/logout")
    let older = syntheticToken(claims: #"{"exp":4102444800,"who":"older"}"#)
    let secrets = InMemorySecrets([.accessToken: older, .account: "old@example.com", .clientID: testClientID])
    let session = SNSession(transport: transport, secrets: secrets)

    let logout = Task { try await session.logOut() }
    await transport.waitForHeldRequest()
    _ = try await session.logIn(account: "new@example.com", password: "pw")
    transport.letThrough()
    try await logout.value

    #expect(try secrets.secret(.accessToken) == liveToken, "the logout erased the login made after it")
    #expect(try secrets.secret(.account) == "new@example.com")
}

@Test("An entry named like the folder it is listed in gets the right path")
func readsAnEntryNamedLikeItsFolder() async throws {
    let transport = ScriptedTransport([.ok(#""entries":[{"tag":"file","id":"7","name":"Foo","path_display":"Foo","size":1}]"#)])
    let session = SNSession(transport: transport, secrets: InMemorySecrets([.accessToken: liveToken, .clientID: testClientID]))
    let entries = try await SNDeviceClient(session: session).list(path: "/Foo")
    #expect(entries.first?.path == "Foo/Foo")
    #expect(entries.first?.parentPath == "Foo")
}

@Test("A multipart upload that fails after S3 started it is aborted, and the failure is the one thrown")
func abortsAFailedMultipartUpload() async throws {
    let size = Int(Transfers.chunkSize) + 1
    let xml = ["Content-Type": "application/xml"]
    func signature(_ name: String) -> ScriptedTransport.Reply {
        .ok(#""s3Authorization":"AWS4-HMAC-SHA256 \#(name)","xamzDate":"20261003T000000Z""#)
    }
    let transport = ScriptedTransport([
        .ok(#""url":"https://uk-ratta-cloud.s3.eu-west-2.amazonaws.com/k.zip","s3Authorization":"a","xamzDate":"d","fileServer":"3","apiServer":"1""#),
        signature("init"),
        .init(body: "<InitiateMultipartUploadResult><UploadId>up-9</UploadId></InitiateMultipartUploadResult>", headers: xml),
        signature("p1"),
        .init(body: ""),                    // a part answered with no ETag
        signature("abort"),
        .init(status: 204),
    ])
    let session = SNSession(
        transport: transport,
        secrets: InMemorySecrets([.accessToken: liveToken, .clientID: testClientID]),
        sleeper: RecordingSleeper()
    )
    await #expect(throws: SNError.malformedResponse("S3 answered part 1 with no ETag")) {
        _ = try await SNDeviceClient(session: session).upload(Data(repeating: 1, count: size), toPath: "/EXPORT/k.zip")
    }
    let abort = try #require(transport.calls.last)
    #expect(abort.httpMethod == "DELETE")
    #expect(abort.url?.query == "uploadId=up-9")
    #expect(transport.calls[transport.calls.count - 2].jsonBody["method"] as? String == "DELETE")
}
