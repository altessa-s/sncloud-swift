// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Synchronization

/// A bounded response reader for data and file-upload tasks.
/// Uploads also report progress while the body goes out.
///
/// Built like `DownloadRouter` and for the same reasons — a delegate is the
/// only way `URLSession` reports progress, and every mutable field sits under a
/// `Mutex` so `Sendable` is honest here rather than asserted.
final class UploadSender: NSObject, URLSessionDataDelegate, Sendable {
    private typealias Outcome = CheckedContinuation<(Data, HTTPURLResponse), any Error>

    private let onProgress: TransferProgress
    private struct State {
        var waiting: Outcome?
        var data = Data()
        var failure: SNError?
        var cancelled = false
    }
    private let state = Mutex(State())

    init(onProgress: @escaping TransferProgress) {
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirect(response, to: request, on: task))
    }

    func run(
        _ request: URLRequest,
        fromFile file: URL? = nil,
        in session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        let task: URLSessionDataTask
        if let file {
            task = session.uploadTask(with: request, fromFile: file)
        } else {
            task = session.dataTask(with: request)
        }
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { held in
                    held.waiting = continuation
                    return held.cancelled
                }
                if cancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            let started = self.state.withLock { held in
                held.cancelled = true
                return held.waiting != nil
            }
            if started { task.cancel() }
        }
    }

    // Count before appending: neither a missing nor a false Content-Length
    // can make a reply allocate more than the response budget.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = state.withLock { held in
            guard held.failure == nil else { return true }
            let count = held.data.count + data.count
            guard count <= SNURLSessionTransport.bodyLimit else {
                held.failure = .oversizedResponse(bytes: count, limit: SNURLSessionTransport.bodyLimit)
                return true
            }
            held.data.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let failure: SNError?
        if !(response is HTTPURLResponse) {
            failure = .malformedResponse("response is not HTTP")
        } else if response.expectedContentLength > Int64(SNURLSessionTransport.bodyLimit) {
            failure = .oversizedResponse(
                bytes: Int(clamping: response.expectedContentLength), limit: SNURLSessionTransport.bodyLimit
            )
        } else {
            failure = nil
        }
        state.withLock { $0.failure = failure }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let held = state.withLock { held in
            let result = held
            held = State()
            return result
        }
        if let failure = held.failure {
            held.waiting?.resume(throwing: failure)
        } else if let error {
            held.waiting?.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            held.waiting?.resume(returning: (held.data, response))
        } else {
            held.waiting?.resume(throwing: SNError.malformedResponse("response is not HTTP"))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
