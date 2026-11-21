// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One open WebSocket, text frames only — all Engine.IO sends on it.
public protocol SNWebSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame, or `nil` once the socket has closed.
    func receive() async throws -> String?
    func close() async
}

/// Opens WebSockets. A port, so that a test can stand in for the network.
public protocol SNWebSocketConnecting: Sendable {
    func connect(to url: URL, userAgent: String) async throws -> any SNWebSocket
}

/// The production connector: `URLSessionWebSocketTask` on a session of its
/// own, so that nothing of the host's — cookies, a shared delegate — rides
/// along.
public struct SNURLSessionWebSocketConnector: SNWebSocketConnecting {
    static let maximumMessageSize = 4 * 1024 * 1024

    public init() {}

    public func connect(to url: URL, userAgent: String) async throws -> any SNWebSocket {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)
        // An announcement of digests carries their text, and a batch of them
        // runs past the 1 MiB default; past this, it is not an announcement.
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
        return URLSessionWebSocket(task: task, session: session)
    }
}

private final class URLSessionWebSocket: SNWebSocket, @unchecked Sendable {
    // `URLSessionWebSocketTask` is thread-safe; the class only carries it.
    let task: URLSessionWebSocketTask
    let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch let error as URLError {
            throw transportFailure(error)
        }
    }

    func receive() async throws -> String? {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return nil
            }
        } catch {
            // A close from either side ends the read with an error; once the
            // task has a close code, that is the socket closing, not a failure.
            if task.closeCode != .invalid { return nil }
            if let error = error as? URLError { throw transportFailure(error) }
            if (error as NSError).domain == NSPOSIXErrorDomain { return nil }
            throw error
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
