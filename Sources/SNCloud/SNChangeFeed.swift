// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import RedactLog
import Synchronization

/// The socket.io channel on which the service announces changes: to files, to
/// the to-do list, to digests — made by another device of the same account.
///
/// **A signal, not a record.** The service queues each announcement for each
/// connection and hands it out on that connection's heartbeat; a connection
/// that drops loses what was queued for it, and a new one starts empty. So an
/// announcement says "look again", and REST says what is there: a host lists
/// after `.connected` — every time, since it marks a fresh connection or a
/// buffer overflow requiring a full refresh — and
/// after each announcement that touches what it shows.
///
/// The feed uses socket.io over Engine.IO 3
/// at `/socket.io/` on `SNEndpoints.socketHost`, the query naming the token,
/// the device as the `channel` header names it (`type`), the same per-process
/// number (`random`), and `sign` — an HMAC-SHA256 of
/// `token_type_random` under a key the app and the server both carry, in
/// base64 with everything but letters and digits removed. Announcements are
/// pushed when the client sends `ratta_ping`, which it does on every
/// heartbeat; each kind is acknowledged with `Received`, which takes it off
/// the server's queue.
///
/// **Your own changes are, mostly, not announced to you.** The service leaves
/// a change out for every connection of the `type` the change's `channel`
/// header named — which is this installation's on every call `SNDeviceClient`,
/// `SNTaskClient` and `SNDigestClient` make. `SNClient` speaks to the web host
/// as the web page does, without that header, so its changes are announced
/// back like anybody else's.
public struct SNChangeFeed: Sendable {
    let session: SNSession
    let connector: any SNWebSocketConnecting
    let sleeper: any SNSleeping
    let openSleeper: any SNSleeping

    public init(
        session: SNSession,
        connector: any SNWebSocketConnecting = SNURLSessionWebSocketConnector(),
        sleeper: any SNSleeping = SNSystemSleeper()
    ) {
        self.session = session
        self.connector = connector
        self.sleeper = sleeper
        openSleeper = SNSystemSleeper()
    }

    init(session: SNSession, connector: any SNWebSocketConnecting, sleeper: any SNSleeping, openSleeper: any SNSleeping) {
        self.session = session
        self.connector = connector
        self.sleeper = sleeper
        self.openSleeper = openSleeper
    }

    /// Open the channel and hand out what it announces, starting with
    /// `.connected`.
    ///
    /// The stream ends when the connection does — the server closing it, the
    /// network dropping it, the token running out — and with an error where
    /// there was one: `sessionExpired` when the server turned the token away,
    /// `rejected` when it turned the signature away. Cancelling the task that
    /// reads it, or dropping it, closes the connection. To stay subscribed,
    /// open it again; to stay correct, list again over REST on every `.connected`,
    /// including a marker emitted when the 256-event buffer overflows.
    public func changes() -> AsyncThrowingStream<SNChange, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SNChange, any Error>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task { [self] in
            do {
                try await run(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - The connection

    /// The URL the official app opens, `ws`/`wss` for its `http`/`https`.
    func url() async throws -> URL {
        let (token, type, random) = try await session.socketCredentials()
        return try await url(token: token, type: type, random: random)
    }

    private func url(token: String, type: String, random: String) async throws -> URL {
        let host = await session.endpoints.socketHost
        guard var parts = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
            throw SNError.malformedResponse("not a socket host: \(host)")
        }
        parts.scheme = parts.scheme?.lowercased() == "http" ? "ws" : "wss"
        parts.path = "/socket.io/"
        parts.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "random", value: random),
            URLQueryItem(name: "sign", value: Self.sign("\(token)_\(type)_\(random)")),
            URLQueryItem(name: "EIO", value: "3"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        // `+` stays literal in a query; the token and the signature have none,
        // but a server that read it as a space would refuse the signature.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw SNError.malformedResponse("no socket URL for \(host)") }
        return url
    }

    /// The handshake's signature. The key is the official app's own, shipped in
    /// it and in the server alike: it proves nothing about who is asking — the
    /// token does that — and only keeps casual clients out.
    static func sign(_ data: String) -> String {
        let key = SymmetricKey(data: Data(signingKey.utf8))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: key))
        return mac.base64EncodedString().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static let signingKey = "K+5xFzxbnB1iSZWqmu3Etw=="

    private func run(_ continuation: AsyncThrowingStream<SNChange, any Error>.Continuation) async throws {
        let (token, type, random) = try await session.socketCredentials()
        let address = try await url(token: token, type: type, random: random)
        let socket = try await connector.connect(to: address, userAgent: SNRequest.appUserAgent)
        Log.supernote.info("change feed: connecting")
        let heartbeat = Heartbeat()
        heartbeat.start { [openSleeper] in
            do {
                try await openSleeper.sleep(for: .seconds(30))
                try Task.checkCancellation()
                if heartbeat.expireOpening() { await socket.close() }
            } catch { /* The open frame or cleanup cancelled the watchdog. */ }
        }
        do {
            // A read waiting on the socket does not notice its task being
            // cancelled; closing the socket is what wakes it.
            try await withTaskCancellationHandler {
                try await read(socket, into: continuation, heartbeat: heartbeat)
            } onCancel: {
                Task { await socket.close() }
            }
        } catch {
            heartbeat.stop()
            await socket.close()
            // The token the server turned away is dropped, as a REST call
            // drops one — that one, not whatever the store holds by now.
            if let refusal = error as? SNError, refusal.meansSessionIsGone {
                await session.invalidate(token)
            }
            throw heartbeat.failure ?? error
        }
        heartbeat.stop()
        await socket.close()
        // A connection the heartbeat gave up on — no frame for too long, or a
        // ping that could not be sent — ends with why, not as a quiet close.
        if let failure = heartbeat.failure { throw failure }
    }

    /// Frames until the connection ends, or the server or the caller ends it.
    private func read(
        _ socket: any SNWebSocket,
        into continuation: AsyncThrowingStream<SNChange, any Error>.Continuation,
        heartbeat: Heartbeat
    ) async throws {
        var opened = false
        var refreshQueued = false
        while let frame = try await socket.receive() {
            try Task.checkCancellation()
            heartbeat.heard()
            switch try Self.read(frame) {
            case .open(let interval, let timeout):
                guard heartbeat.markOpened() else { return }
                heartbeat.start { [sleeper] in
                    await Self.beat(socket, every: interval, allowing: timeout, sleeper: sleeper, heartbeat: heartbeat)
                }
            case .connected:
                guard !opened else { continue }
                opened = true
                Log.supernote.info("change feed: connected")
                continuation.yield(.connected)
                // Whatever is queued already, asked for at once rather than on
                // the first beat.
                try await socket.send(Self.packet(event: "ratta_ping", "ping"))
            case .closed:
                Log.supernote.info("change feed: closed by the server")
                return
            case .event(let name, let argument):
                if let change = try Self.change(event: name, argument: argument) {
                    try await socket.send(Self.packet(event: name, "Received"))
                    switch continuation.yield(change) {
                    case .dropped(let dropped):
                        // Replace a marker only when it too was evicted. This
                        // keeps one refresh queued through sustained overflow.
                        if !refreshQueued || dropped == .connected {
                            continuation.yield(.connected)
                            refreshQueued = true
                        }
                    case .enqueued(let remaining):
                        if remaining > 0 { refreshQueued = false }
                    case .terminated:
                        return
                    @unknown default:
                        break
                    }
                }
            case .ignored:
                continue
            }
        }
        Log.supernote.info("change feed: the connection ended")
    }

    /// The two heartbeats, on the interval the server named: Engine.IO's ping,
    /// which keeps the connection, and `ratta_ping`, which makes the server
    /// push what it has queued.
    ///
    /// The server answers each ping with a pong, so a connection that has
    /// sent nothing for the interval and the timeout it named is half open:
    /// the heartbeat closes it rather than leave it looking connected. A ping
    /// that cannot be sent closes it too. Either way the read wakes and the
    /// feed ends with why.
    private static func beat(
        _ socket: any SNWebSocket,
        every interval: Duration,
        allowing timeout: Duration,
        sleeper: any SNSleeping,
        heartbeat: Heartbeat
    ) async {
        do {
            while !Task.isCancelled {
                try await sleeper.sleep(for: interval)
                guard heartbeat.silence() <= interval + timeout else {
                    Log.supernote.error("change feed: nothing from the server for too long")
                    heartbeat.fail(SNError.transport(code: URLError.timedOut.rawValue))
                    await socket.close()
                    return
                }
                try await socket.send("2")
                try await socket.send(packet(event: "ratta_ping", "ping"))
            }
        } catch {
            // Stopped: whatever a send in flight threw is the stop, not a
            // failure of the connection.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            heartbeat.fail(error as? SNError ?? SNError.transport(code: URLError.networkConnectionLost.rawValue))
            await socket.close()
        }
    }

    // MARK: - Engine.IO and socket.io, as far as this channel needs them

    enum Frame: Equatable {
        case open(interval: Duration, timeout: Duration)
        case connected
        case closed
        case event(name: String, argument: String?)
        case ignored
    }

    /// One text frame. Engine.IO's first digit is the packet type — `0` open,
    /// `1` close, `3` pong, `4` a socket.io packet, `6` noop — and a socket.io
    /// packet's is `0` connect, `1` disconnect, `2` event, `4` error.
    static func read(_ frame: String) throws -> Frame {
        guard let engine = frame.first else { return .ignored }
        let rest = frame.dropFirst()
        switch engine {
        case "0":
            let open = try? JSONDecoder().decode(Open.self, from: Data(rest.utf8))
            return .open(
                interval: .milliseconds(max(1_000, min(open?.pingInterval ?? 25_000, 300_000))),
                timeout: .milliseconds(max(1_000, min(open?.pingTimeout ?? 60_000, 300_000)))
            )
        case "1":
            return .closed
        case "4":
            guard let packet = rest.first else { return .ignored }
            switch packet {
            case "0": return .connected
            case "1": return .closed
            case "2": return try event(String(rest.dropFirst()))
            case "4": throw SNError.rejected(code: "socket.io", message: String(rest.dropFirst()))
            default: return .ignored
            }
        default:
            return .ignored
        }
    }

    /// `["name", argument]`, after an optional namespace and acknowledgement
    /// number this channel never uses.
    private static func event(_ body: String) throws -> Frame {
        guard let start = body.firstIndex(of: "["),
              let array = try? JSONSerialization.jsonObject(with: Data(body[start...].utf8)) as? [Any],
              let name = array.first as? String
        else { throw SNError.malformedResponse("a socket.io event that is not one") }
        return .event(name: name, argument: array.dropFirst().first as? String)
    }

    /// A socket.io event packet with one string argument.
    static func packet(event name: String, _ argument: String) -> String {
        let array = [name, argument]
        let data = (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8)
        return "42" + String(decoding: data, as: UTF8.self)
    }

    /// What an event announces, or `nil` for one that announces nothing — the
    /// heartbeat's answer, a status `"true"`.
    static func change(event name: String, argument: String?) throws -> SNChange? {
        guard [Event.files, Event.tasks, Event.digests].contains(name),
              let argument, argument.first == "{"
        else { return nil }
        let data = Data(argument.utf8)
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let code = envelope?.code ?? ""
        guard code == "200" else {
            let message = envelope?.msg ?? ""
            Log.supernote.error("change feed refused: \(code, .public)")
            // The two refusals the server makes on connecting: a token it does
            // not accept, and a signature it does not.
            if message.lowercased().contains("token") { throw SNError.sessionExpired }
            throw SNError.rejected(code: code, message: message)
        }
        do {
            switch name {
            case Event.files: return .files(try JSONDecoder().decode(Batch<SNFileChange>.self, from: data).data ?? [])
            case Event.tasks: return .tasks(try JSONDecoder().decode(Batch<SNTaskChange>.self, from: data).data ?? [])
            default: return .digests(try JSONDecoder().decode(Batch<SNDigestChange>.self, from: data).data ?? [])
            }
        } catch {
            throw SNError.malformedResponse("a \(name) announcement: \(error)")
        }
    }

    enum Event {
        static let files = "ServerMessage"
        static let tasks = "to-do"
        static let digests = "digest"
    }

    private struct Open: Decodable {
        let pingInterval: Int?
        let pingTimeout: Int?
    }

    private struct Envelope: Decodable {
        let code: String?
        let msg: String?
    }

    private struct Batch<Item: Decodable>: Decodable {
        let data: [Item]?
    }
}

// MARK: - What is announced

/// One announcement.
///
/// Frozen, for the reason given on `SNError`.
@frozen
public enum SNChange: Sendable {
    /// List again: the channel opened, or a slow reader overflowed its buffer.
    case connected
    /// Files or folders were added, changed, moved, copied or deleted.
    case files([SNFileChange])
    /// Something in the to-do list changed — which task the announcement may
    /// name, but not how.
    case tasks([SNTaskChange])
    /// A digest, a digest group or a tag was added, changed or deleted.
    case digests([SNDigestChange])
}

// Equality spelled out rather than synthesised; see `SNError`.
extension SNChange: Equatable {
    public static func == (lhs: SNChange, rhs: SNChange) -> Bool {
        switch (lhs, rhs) {
        case (.connected, .connected): true
        case let (.files(left), .files(right)): left == right
        case let (.tasks(left), .tasks(right)): left == right
        case let (.digests(left), .digests(right)): left == right
        default: false
        }
    }
}

/// What kind of change an announcement is about, under the service's own
/// name. A struct rather than an enum, so that a name the service adds later
/// still arrives.
public struct SNChangeKind: RawRepresentable, Hashable, Sendable, Decodable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    // Files. `DOWNLOADFILE` is the service's word for a file that arrived.
    public static let fileAdded = SNChangeKind(rawValue: "DOWNLOADFILE")
    public static let folderAdded = SNChangeKind(rawValue: "ADDFOLDER")
    public static let fileModified = SNChangeKind(rawValue: "MODIFYFILE")
    public static let folderModified = SNChangeKind(rawValue: "MODIFYFOLDER")
    public static let fileDeleted = SNChangeKind(rawValue: "DELETEFILE")
    public static let folderDeleted = SNChangeKind(rawValue: "DELETEFOLDER")
    public static let fileCopied = SNChangeKind(rawValue: "COPYFILE")
    public static let folderCopied = SNChangeKind(rawValue: "COPYFOLDER")
    public static let fileMoved = SNChangeKind(rawValue: "MOVEFILE")
    public static let folderMoved = SNChangeKind(rawValue: "MOVEFOLDER")
    /// Another device holds the sync lock.
    public static let waiting = SNChangeKind(rawValue: "WAITING")
    public static let syncStarted = SNChangeKind(rawValue: "STARTSYNC")
    // The to-do list: something changed, or the order did.
    public static let tasksChanged = SNChangeKind(rawValue: "QUERY")
    public static let tasksSorted = SNChangeKind(rawValue: "SORT")
    // Digests.
    public static let digestAdded = SNChangeKind(rawValue: "ADD_DIGEST")
    public static let digestUpdated = SNChangeKind(rawValue: "UPDATE_DIGEST")
    public static let digestDeleted = SNChangeKind(rawValue: "DELETE_DIGEST")
}

/// A change to a file or a folder, as the service announces it.
public struct SNFileChange: Sendable, Equatable {
    public let kind: SNChangeKind
    public let isFolder: Bool
    public let id: SNFileID?
    /// A copy's identifier.
    public let newID: SNFileID?
    public let name: String?
    public let newName: String?
    public let md5: String?
    public let size: Int64?
    /// The folder it was in.
    public let folderID: SNFileID?
    /// The folder it went to, for a move or a copy.
    public let destinationID: SNFileID?
    public let path: String?
    public let newPath: String?
    /// The device that made the change, as the service names it.
    public let device: String?
    public let time: Date?

    public init(
        kind: SNChangeKind,
        isFolder: Bool = false,
        id: SNFileID? = nil,
        newID: SNFileID? = nil,
        name: String? = nil,
        newName: String? = nil,
        md5: String? = nil,
        size: Int64? = nil,
        folderID: SNFileID? = nil,
        destinationID: SNFileID? = nil,
        path: String? = nil,
        newPath: String? = nil,
        device: String? = nil,
        time: Date? = nil
    ) {
        self.kind = kind
        self.isFolder = isFolder
        self.id = id
        self.newID = newID
        self.name = name
        self.newName = newName
        self.md5 = md5
        self.size = size
        self.folderID = folderID
        self.destinationID = destinationID
        self.path = path
        self.newPath = newPath
        self.device = device
        self.time = time
    }
}

extension SNFileChange: Decodable {
    private enum Keys: String, CodingKey {
        case messageType, equipmentNo, fileType, id, newId, originalName, newName, md5, size
        case directoryId, goDirectoryId, originalPath, newPath, timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        kind = SNChangeKind(rawValue: container.text(.messageType) ?? "")
        // `FOLDE` is the service's spelling.
        isFolder = container.text(.fileType)?.uppercased().hasPrefix("FOLD") ?? false
        id = container.integer(.id).map(SNFileID.init(rawValue:))
        newID = container.integer(.newId).map(SNFileID.init(rawValue:))
        name = container.text(.originalName)
        newName = container.text(.newName)
        md5 = container.text(.md5)?.lowercased()
        size = container.integer(.size)
        folderID = container.integer(.directoryId).map(SNFileID.init(rawValue:))
        destinationID = container.integer(.goDirectoryId).map(SNFileID.init(rawValue:))
        path = container.text(.originalPath)
        newPath = container.text(.newPath)
        device = container.text(.equipmentNo)
        time = container.time(.timestamp)
    }
}

/// A change to the to-do list.
public struct SNTaskChange: Sendable, Equatable {
    public let kind: SNChangeKind
    public let listID: String?
    public let taskID: String?
    public let device: String?
    public let time: Date?

    public init(kind: SNChangeKind, listID: String? = nil, taskID: String? = nil, device: String? = nil, time: Date? = nil) {
        self.kind = kind
        self.listID = listID
        self.taskID = taskID
        self.device = device
        self.time = time
    }
}

extension SNTaskChange: Decodable {
    private enum Keys: String, CodingKey { case messageType, equipmentNo, taskListId, taskId, timestamp }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        kind = SNChangeKind(rawValue: container.text(.messageType) ?? "")
        listID = container.text(.taskListId)
        taskID = container.text(.taskId)
        device = container.text(.equipmentNo)
        time = container.time(.timestamp)
    }
}

/// A change to a digest, a digest group or a tag.
public struct SNDigestChange: Sendable, Equatable {
    /// Which of the three changed.
    public struct Item: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let group = Item(rawValue: "1")
        public static let digest = Item(rawValue: "2")
        public static let tag = Item(rawValue: "3")
    }

    public let kind: SNChangeKind
    public let item: Item
    public let id: SNDigestID?
    /// The digest's group, by its `uniqueIdentifier`.
    public let groupIdentifier: String?
    public let uniqueIdentifier: String?
    public let device: String?
    public let time: Date?

    public init(
        kind: SNChangeKind,
        item: Item,
        id: SNDigestID? = nil,
        groupIdentifier: String? = nil,
        uniqueIdentifier: String? = nil,
        device: String? = nil,
        time: Date? = nil
    ) {
        self.kind = kind
        self.item = item
        self.id = id
        self.groupIdentifier = groupIdentifier
        self.uniqueIdentifier = uniqueIdentifier
        self.device = device
        self.time = time
    }
}

extension SNDigestChange: Decodable {
    private enum Keys: String, CodingKey {
        case messageType, dataType, equipmentNo, id, uniqueIdentifier, parentUniqueIdentifier, timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        kind = SNChangeKind(rawValue: container.text(.messageType) ?? "")
        item = Item(rawValue: container.text(.dataType) ?? container.integer(.dataType).map(String.init) ?? "")
        id = container.integer(.id).map(SNDigestID.init(rawValue:))
        groupIdentifier = container.text(.parentUniqueIdentifier)
        uniqueIdentifier = container.text(.uniqueIdentifier)
        device = container.text(.equipmentNo)
        time = container.time(.timestamp)
    }
}

extension SNChangeFeed {
    /// The heartbeat's task, held where both the read loop and the cleanup
    /// after it can reach it, with when a frame last arrived and why the
    /// heartbeat gave up, if it did.
    private struct Opening {
        var opened = false
        var failure: SNError?
    }

    final class Heartbeat: Sendable {
        private let task = Mutex<Task<Void, Never>?>(nil)
        private let lastHeard = Mutex(ContinuousClock.now)
        private let opening = Mutex(Opening())

        func markOpened() -> Bool {
            opening.withLock { state in
                guard state.failure == nil else { return false }
                state.opened = true
                return true
            }
        }

        func expireOpening() -> Bool {
            opening.withLock { state in
                guard !state.opened, state.failure == nil else { return false }
                state.failure = .transport(code: URLError.timedOut.rawValue)
                return true
            }
        }

        func heard() {
            lastHeard.withLock { $0 = ContinuousClock.now }
        }

        func silence() -> Duration {
            ContinuousClock.now - lastHeard.withLock { $0 }
        }

        func fail(_ error: SNError) {
            opening.withLock { $0.failure = $0.failure ?? error }
        }

        var failure: SNError? { opening.withLock { $0.failure } }

        func start(_ body: @escaping @Sendable () async -> Void) {
            let started = Task { await body() }
            task.withLock { held in
                held?.cancel()
                held = started
            }
        }

        func stop() {
            task.withLock { held in
                held?.cancel()
                held = nil
            }
        }
    }
}
