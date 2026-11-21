// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Synchronization

/// The download delegate: progress reports, ceilings and finished files, for
/// every download in the process.
///
/// A class because `URLSession` reports through a delegate, and one instance
/// because the session is one — the reports are sorted out by
/// `taskIdentifier`, which is unique among a session's live tasks. All the
/// mutable state is under a `Mutex`, so `Sendable` here is honest, without
/// `@unchecked`.
///
/// Progress reaches only the **session** delegate: the task delegate that
/// `download(for:delegate:)` accepts is never told about bytes written. Hence
/// one shared session with this router behind it, rather than a session per
/// download.
final class DownloadRouter: NSObject, URLSessionDownloadDelegate, Sendable {
    private typealias Outcome = CheckedContinuation<(URL, HTTPURLResponse), any Error>

    private struct Waiting {
        let ceiling: DownloadCeiling
        let onProgress: TransferProgress
        let outcome: Outcome
    }

    private let waiting = Mutex<[Int: Waiting]>([:])

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirect(response, to: request, on: task))
    }

    /// Download and wait. Cancellation of the task passes straight through:
    /// `URLSession` answers it with an error, and that is what we hand upwards.
    func run(
        _ request: URLRequest,
        ceiling: DownloadCeiling,
        onProgress: @escaping TransferProgress,
        in session: URLSession
    ) async throws -> (URL, HTTPURLResponse) {
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Filed before the task is started, so that no report can
                // arrive before there is anybody to hand it to.
                waiting.withLock {
                    $0[task.taskIdentifier] = Waiting(
                        ceiling: ceiling,
                        onProgress: onProgress,
                        outcome: continuation
                    )
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Wake one waiter exactly once: success comes from
    /// `didFinishDownloadingTo`, an error from `didCompleteWithError`, and on a
    /// successful download both are called.
    private func finish(_ task: Int, _ result: Result<(URL, HTTPURLResponse), any Error>) {
        guard let waiter = waiting.withLock({ $0.removeValue(forKey: task) }) else {
            // Nobody is waiting any more — the download was refused over its
            // ceiling while its completion was already on the way. A file it
            // claimed would otherwise stay in the temporary directory.
            if case .success(let (file, _)) = result { try? FileManager.default.removeItem(at: file) }
            return
        }
        waiter.outcome.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // The continuation stays in the table: a copy taken out here would be
        // a second chance to resume it, and resuming twice traps.
        let waiter = waiting.withLock { held -> (DownloadCeiling, TransferProgress)? in
            held[downloadTask.taskIdentifier].map { ($0.ceiling, $0.onProgress) }
        }
        guard let (ceiling, onProgress) = waiter else { return }
        if let refusal = ceiling.refusal(
            written: totalBytesWritten,
            expected: totalBytesExpectedToWrite
        ) {
            // Cancelling is what stops the bytes, and it takes the part-written
            // file with it. The `didCompleteWithError` the cancellation brings
            // along finds no waiter and does nothing.
            downloadTask.cancel()
            finish(downloadTask.taskIdentifier, .failure(refusal))
            return
        }
        onProgress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw SNError.malformedResponse("response is not HTTP")
            }
            // The file lives only until this method returns — claimed at once.
            finish(downloadTask.taskIdentifier, .success((try ScratchFile.claim(location), response)))
        } catch {
            finish(downloadTask.taskIdentifier, .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        finish(task.taskIdentifier, .failure(error))
    }
}
