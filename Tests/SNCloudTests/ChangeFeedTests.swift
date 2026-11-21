// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Synchronization
import Testing

// The scripted socket supplies Engine.IO 3 and socket.io event frames.

/// A socket that hands out a script of frames, then reports itself closed,
/// and records what was sent on it.
final class ScriptedSocket: SNWebSocket, SNWebSocketConnecting {
    private let frames: Mutex<[String]>
    private let sentFrames = Mutex<[String]>([])
    private let opened = Mutex<[URL]>([])
    private let agents = Mutex<[String]>([])
    let closed = Mutex(false)

    init(_ frames: [String]) {
        self.frames = Mutex(frames)
    }

    var sent: [String] { sentFrames.withLock { $0 } }
    var urls: [URL] { opened.withLock { $0 } }
    var userAgents: [String] { agents.withLock { $0 } }

    func connect(to url: URL, userAgent: String) async throws -> any SNWebSocket {
        opened.withLock { $0.append(url) }
        agents.withLock { $0.append(userAgent) }
        return self
    }

    func send(_ text: String) async throws {
        sentFrames.withLock { $0.append(text) }
    }

    func receive() async throws -> String? {
        // A breath between frames, so that the heartbeat task gets its turn.
        await Task.yield()
        return frames.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    func close() async {
        closed.withLock { $0 = true }
    }
}

/// A sleeper that never wakes: the heartbeat's loop waits here until the feed
/// is done with it.
struct NeverWakes: SNSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

private let openFrame = #"0{"sid":"21739e0d-4372-4630-9e07-74de192b5e5e","upgrades":["websocket"],"pingInterval":5000,"pingTimeout":25000}"#

private func feed(
    _ socket: any SNWebSocketConnecting,
    endpoints: SNEndpoints = .official,
    sleeper: any SNSleeping = NeverWakes(),
    openSleeper: any SNSleeping = SNSystemSleeper()
) -> SNChangeFeed {
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com", .clientID: testClientID])
    let session = SNSession(
        endpoints: endpoints, transport: ScriptedTransport([]), secrets: secrets,
        now: { Date(timeIntervalSince1970: 1_780_000_000) }, sleeper: RecordingSleeper()
    )
    return SNChangeFeed(session: session, connector: socket, sleeper: sleeper, openSleeper: openSleeper)
}

private func collect(_ stream: AsyncThrowingStream<SNChange, any Error>) async throws -> [SNChange] {
    var changes: [SNChange] = []
    for try await change in stream { changes.append(change) }
    return changes
}

/// An event frame as the server writes it: the argument is JSON in a string.
private func eventFrame(_ name: String, _ json: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [name, json])) ?? Data()
    return "42" + String(decoding: data, as: UTF8.self)
}

@Test("Feed signatures retain only letters and digits from the base64 HMAC-SHA256")
func signsAsTheServerDoes() {
    // Same expired, unsigned JWT as sncloud-go. Python hmac supplies the expected value.
    let data = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJ1c2VySWQiOjEsImV4cCI6MX0._ANDROID_1002"
    #expect(SNChangeFeed.sign(data) == "sGp919U8eJMJo3HBbtxhgqjmXlDgM7LZ0bz5DNp9w")
}

@Test("The channel opens where and as the official app opens it")
func opensTheChannelAsTheApp() async throws {
    let socket = ScriptedSocket([openFrame, "40"])
    let changes = try await collect(feed(socket).changes())

    #expect(changes == [.connected])
    let url = try #require(socket.urls.first)
    #expect(url.scheme == "wss")
    #expect(url.host() == "app-wss-file.supernote.com")
    #expect(url.path() == "/socket.io/")
    let query = Dictionary(
        uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    let type = "\(SNDeviceIdentity.currentPlatform)\(testClientID)"
    #expect(query["token"] == liveToken)
    #expect(query["type"] == type)
    #expect(query["random"] == "1780000000000")
    #expect(query["sign"] == SNChangeFeed.sign("\(liveToken)_\(type)_1780000000000"))
    #expect(query["EIO"] == "3")
    #expect(query["transport"] == "websocket")
    #expect(socket.userAgents == ["Dart/3.8 (dart:io)"])
    // The heartbeat asks for what is queued straight away.
    #expect(socket.sent.contains(#"42["ratta_ping","ping"]"#))
}

@Test("A private cloud's channel is on its own host, in plain ws where it speaks plain HTTP")
func opensAPrivateCloudsChannel() async throws {
    let socket = ScriptedSocket([openFrame, "40"])
    _ = try await collect(feed(socket, endpoints: .privateCloud(URL.constant("http://127.0.0.1:19072"))).changes())
    let url = try #require(socket.urls.first)
    #expect(url.absoluteString.hasPrefix("ws://127.0.0.1:19072/socket.io/?"))
}

@Test("Announcements of files, tasks and digests are read and acknowledged")
func readsAndAcknowledgesAnnouncements() async throws {
    let files = #"""
    {"code":"200","msg":null,"timestamp":946684802000,"msgType":"FILE-SYN","data":[
     {"messageType":"MOVEFILE","equipmentNo":"SN000000000000-ANDROIDabc","fileType":"FILE","id":900000000000000005,
      "originalName":"Sample.note","md5":"20439F79E4E9DC95BE34B21029221F80","size":4096,"directoryId":5,"goDirectoryId":6,
      "originalPath":"NOTE/Note/","newPath":"NOTE/Note/Archive/","timestamp":946684802000},
     {"messageType":"ADDFOLDER","fileType":"FOLDE","id":7,"newName":"Archive","directoryId":5}]}
    """#
    let tasks = #"{"code":"200","msgType":"TASK-SYN","data":[{"messageType":"QUERY","taskListId":"1","taskId":"c0ffee","timestamp":946684802000}]}"#
    let digests = #"""
    {"code":"200","msgType":"DIGEST-SYN","data":[
     {"messageType":"ADD_DIGEST","dataType":"2","id":900000000000000003,"parentUniqueIdentifier":"g-1"}]}
    """#
    let socket = ScriptedSocket([
        openFrame, "40", #"42["ratta_ping","Received"]"#, "3",
        eventFrame("ServerMessage", files), eventFrame("to-do", tasks), eventFrame("digest", digests),
        #"42["ServerMessage","true"]"#,
    ])

    let changes = try await collect(feed(socket).changes())

    #expect(changes == [
        .connected,
        .files([
            SNFileChange(
                kind: .fileMoved, id: SNFileID(rawValue: 900_000_000_000_000_005), name: "Sample.note",
                md5: "20439f79e4e9dc95be34b21029221f80", size: 4_096, folderID: SNFileID(rawValue: 5),
                destinationID: SNFileID(rawValue: 6), path: "NOTE/Note/", newPath: "NOTE/Note/Archive/",
                device: "SN000000000000-ANDROIDabc", time: Date(timeIntervalSince1970: 946_684_802)
            ),
            SNFileChange(
                kind: .folderAdded, isFolder: true, id: SNFileID(rawValue: 7), newName: "Archive", folderID: SNFileID(rawValue: 5)
            ),
        ]),
        .tasks([SNTaskChange(kind: .tasksChanged, listID: "1", taskID: "c0ffee", time: Date(timeIntervalSince1970: 946_684_802))]),
        .digests([SNDigestChange(kind: .digestAdded, item: .digest, id: SNDigestID(rawValue: 900_000_000_000_000_003), groupIdentifier: "g-1")]),
    ])
    // Each kind acknowledged on its own event, which takes it off the queue.
    #expect(socket.sent.contains(#"42["ServerMessage","Received"]"#))
    #expect(socket.sent.contains(#"42["to-do","Received"]"#))
    #expect(socket.sent.contains(#"42["digest","Received"]"#))
}

@Test("A token the server turns away ends the stream with sessionExpired; a signature, with rejected")
func endsOnARefusal() async throws {
    let token = ScriptedSocket([openFrame, "40", eventFrame("ServerMessage", #"{"code":"403","msg":"token校验不通过，拒绝连接"}"#)])
    await #expect(throws: SNError.sessionExpired) { _ = try await collect(feed(token).changes()) }

    let sign = ScriptedSocket([openFrame, "40", eventFrame("ServerMessage", #"{"code":"403","msg":"sign值校验不通过，拒绝连接"}"#)])
    await #expect(throws: SNError.rejected(code: "403", message: "sign值校验不通过，拒绝连接")) {
        _ = try await collect(feed(sign).changes())
    }
}

@Test("A close from the server ends the stream, and the socket is closed behind it")
func endsWhenTheServerCloses() async throws {
    let socket = ScriptedSocket([openFrame, "40", "41", eventFrame("to-do", #"{"code":"200","data":[]}"#)])
    let changes = try await collect(feed(socket).changes())
    #expect(changes == [.connected])
    #expect(socket.closed.withLock { $0 })
}

@Test("Engine.IO's packets are read by their first digits")
func readsEngineIOFrames() throws {
    #expect(try SNChangeFeed.read(openFrame) == .open(interval: .milliseconds(5000), timeout: .milliseconds(25_000)))
    #expect(try SNChangeFeed.read("40") == .connected)
    #expect(try SNChangeFeed.read("1") == .closed)
    #expect(try SNChangeFeed.read("3") == .ignored)
    #expect(try SNChangeFeed.read(#"42["to-do","x"]"#) == .event(name: "to-do", argument: "x"))
    #expect(throws: SNError.self) { try SNChangeFeed.read(#"44"bad namespace""#) }
    #expect(SNChangeFeed.packet(event: "ratta_ping", "ping") == #"42["ratta_ping","ping"]"#)
}

/// A socket that hands out its frames, then waits — as a quiet connection
/// does — until it is closed. Whether it is closed and who waits for that are
/// one state under one lock: kept apart, a close could slip between the check
/// and the wait, and the wait would never end.
final class QuietSocket: SNWebSocket, SNWebSocketConnecting {
    private struct State {
        var frames: [String]
        var closed = false
        var waiter: CheckedContinuation<String?, Never>?
    }

    private let state: Mutex<State>
    private let failsPings: Bool

    init(_ frames: [String], failsPings: Bool = false) {
        state = Mutex(State(frames: frames))
        self.failsPings = failsPings
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    func connect(to url: URL, userAgent: String) async throws -> any SNWebSocket { self }

    func send(_ text: String) async throws {
        if failsPings, text == "2" { throw SNError.transport(code: URLError.networkConnectionLost.rawValue) }
    }

    func receive() async throws -> String? {
        if let frame = state.withLock({ $0.frames.isEmpty ? nil : $0.frames.removeFirst() }) { return frame }
        return await withCheckedContinuation { continuation in
            let closedAlready = state.withLock { value -> Bool in
                if value.closed { return true }
                value.waiter = continuation
                return false
            }
            if closedAlready { continuation.resume(returning: nil) }
        }
    }

    func close() async {
        let waiter = state.withLock { value -> CheckedContinuation<String?, Never>? in
            value.closed = true
            defer { value.waiter = nil }
            return value.waiter
        }
        waiter?.resume(returning: nil)
    }
}

/// A sleeper that wakes at once.
struct WakesAtOnce: SNSleeping {
    func sleep(for duration: Duration) async throws {
        await Task.yield()
    }
}

@Test("A reader that stops listening closes the connection, though no frame is coming")
func closesWhenTheReaderStops() async throws {
    let socket = QuietSocket([openFrame, "40"])
    for try await change in feed(socket).changes() where change == .connected { break }
    // Dropping the stream cancels the feed; the close is what wakes the read.
    for _ in 0..<100 where !socket.isClosed {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(socket.isClosed)
}

@Test("A token the change feed was turned away with is dropped from the store, as a REST refusal drops it")
func dropsATokenTheFeedWasRefused() async throws {
    let socket = ScriptedSocket([openFrame, "40", eventFrame("ServerMessage", #"{"code":"403","msg":"token校验不通过，拒绝连接"}"#)])
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com", .clientID: testClientID])
    let session = SNSession(endpoints: .official, transport: ScriptedTransport([]), secrets: secrets, sleeper: RecordingSleeper())
    let feed = SNChangeFeed(session: session, connector: socket, sleeper: NeverWakes())

    await #expect(throws: SNError.sessionExpired) { _ = try await collect(feed.changes()) }
    #expect(try secrets.secret(.accessToken) == nil)
    #expect(try secrets.secret(.clientID) == testClientID)
}

@Test("A ping that cannot be sent ends the feed with why, though the read was waiting")
func endsWhenAPingFails() async throws {
    let socket = QuietSocket([openFrame, "40"], failsPings: true)
    var seen: [SNChange] = []
    await #expect(throws: SNError.transport(code: URLError.networkConnectionLost.rawValue)) {
        for try await change in feed(socket, sleeper: WakesAtOnce()).changes() { seen.append(change) }
    }
    #expect(seen == [.connected])
    #expect(socket.isClosed)
}

@Test("A connection the server has gone quiet on past its own timeout is closed, not left looking connected")
func endsWhenTheServerGoesQuiet() async throws {
    // The shortest interval and timeout the feed accepts: one second each.
    let quick = #"0{"sid":"s","upgrades":[],"pingInterval":1000,"pingTimeout":1000}"#
    let socket = QuietSocket([quick, "40"])
    await #expect(throws: SNError.transport(code: URLError.timedOut.rawValue)) {
        for try await _ in feed(socket, sleeper: SNSystemSleeper()).changes() {}
    }
    #expect(socket.isClosed)
}

@Test("A slow change-feed reader gets a bounded queue and a full refresh signal")
func feedOverflow() async throws {
    let event = eventFrame("to-do", #"{"code":"200","msgType":"TASK-SYN","data":[{"messageType":"QUERY","taskId":"synthetic"}]}"#)
    let socket = ScriptedSocket([openFrame, "40"] + Array(repeating: event, count: 1000))
    let stream = feed(socket).changes()
    await until("the feed to finish producing") { socket.closed.withLock { $0 } }
    let changes = try await collect(stream)
    #expect(changes.count <= 256)
    #expect(changes.filter { $0 == .connected }.count == 1)
    #expect(socket.sent.filter { $0.contains("Received") }.count == 1000)
}

private actor SilentSocket: SNWebSocket, SNWebSocketConnecting {
    var waiting: CheckedContinuation<String?, Never>?
    var closed = false

    func connect(to url: URL, userAgent: String) async throws -> any SNWebSocket { self }
    func send(_ text: String) async throws {}
    func receive() async throws -> String? {
        if closed { return nil }
        return await withCheckedContinuation { waiting = $0 }
    }
    func close() async {
        closed = true
        waiting?.resume(returning: nil)
        waiting = nil
    }
}

@Test("A connection without an Engine.IO open frame times out and closes")
func openWatchdog() async throws {
    let socket = SilentSocket()
    let sleeper = RecordingSleeper()
    let reading = Task { try await collect(feed(socket, openSleeper: sleeper).changes()) }
    await until("the open-frame watchdog to close the socket") { await socket.closed }
    // Also unblock the reader on regression, so this test fails rather than hangs.
    await socket.close()
    await #expect(throws: SNError.transport(code: URLError.timedOut.rawValue)) {
        _ = try await reading.value
    }
    #expect(await socket.closed)
    #expect(sleeper.delays == [.seconds(30)])
}

@Test("An accepted open frame prevents a late watchdog from failing the connection")
func openWatchdogAfterOpen() {
    let heartbeat = SNChangeFeed.Heartbeat()
    #expect(heartbeat.markOpened())
    #expect(!heartbeat.expireOpening())
    #expect(heartbeat.failure == nil)
}

@Test("An expired opening cannot subsequently become an open connection")
func openAfterWatchdog() {
    let heartbeat = SNChangeFeed.Heartbeat()
    #expect(heartbeat.expireOpening())
    #expect(!heartbeat.markOpened())
    #expect(heartbeat.failure == .transport(code: URLError.timedOut.rawValue))
}
