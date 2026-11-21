// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The one thing the small requests need a delegate for: meeting a redirect.
///
/// `URLSession` follows one silently, so without this a hop is invisible. What
/// the hop is allowed to carry is decided in `followRedirect`, which is where
/// all three of this package's delegates send it.
final class RedirectWatcher: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirect(response, to: request, on: task))
    }
}
