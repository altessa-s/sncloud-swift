// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The network abstraction: it lets the client be run in tests without a
/// server.
public protocol SNTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Download the body into a temporary file, refused the moment it runs past
    /// `limitBytes`, reporting progress.
    ///
    /// The file passes into the caller's ownership. Kept apart from `send`
    /// because a document runs to hundreds of megabytes: memory is no place for
    /// it, and the ceiling has to be applied while the bytes can still be
    /// stopped — a caller holding a finished file has already paid the disk.
    func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse)

    /// Send a file as the body, reporting progress. The mirror image of
    /// `download`, and there for the same reason.
    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        onProgress: @escaping TransferProgress
    ) async throws -> (Data, HTTPURLResponse)
}

public extension SNTransporting {
    /// The default goes through `send`. Doubles in tests have no need for the
    /// file path, and a double serves what the fixture wrote — it has nothing
    /// to overrun, so no ceiling is kept here.
    func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let url = try ScratchFile.write(data)
        onProgress(Int64(data.count), Int64(data.count))
        return (url, response)
    }

    /// The default reads the file and goes through `send`, so a test double
    /// finds the bytes where it already looks for them — in `httpBody`. The
    /// production transport overrides this so real documents never take this
    /// path.
    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        onProgress: @escaping TransferProgress
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let body = try Data(contentsOf: file)
        request.httpBody = body
        let result = try await send(request)
        onProgress(Int64(body.count), Int64(body.count))
        return result
    }
}

public struct SNURLSessionTransport: SNTransporting {
    let session: URLSession

    public init(session: URLSession = requests) {
        self.session = session
    }

    /// Strip the response cache and the cookie store off a configuration,
    /// whoever it came from.
    ///
    /// The cache, because the default configuration writes answered requests
    /// to `URLCache.shared`, on disk, in the host's container — and the answer
    /// to a login *is* the access token, in plain text. Nothing is lost by
    /// refusing it: a listing is asked for precisely to learn whether it
    /// changed.
    ///
    /// The cookies, because they are part of the session and the session is
    /// this package's: the XSRF cookie has to pair with the header on the next
    /// request, and `HTTPCookieStorage.shared` is a process-wide store that the
    /// host, its web views and anything else may write to. `SNChannel` keeps
    /// the jar instead, where a logout can empty it and a test can read it.
    static func isolated(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    /// The one session the small requests run on, shared so that its
    /// connection pool is. Public because it is named in a public initialiser's
    /// default argument.
    public static let requests = URLSession(
        configuration: isolated(.default),
        delegate: RedirectWatcher(),
        delegateQueue: nil
    )

    /// The ceiling on a body read into memory. Everything on this path is a
    /// JSON answer, and the longest is the device API's recursive listing: the
    /// whole tree in one answer, a few hundred bytes to the entry — ten
    /// thousand files is a few megabytes. Thirty-two is a line drawn far past
    /// that, so that a body which is not the protocol's at all cannot be
    /// carried upwards as if it were.
    ///
    /// Enforced by the data delegate before each chunk is appended, including
    /// upload replies. An oversized declared length is refused at the headers.
    public static let bodyLimit = 32 * 1024 * 1024

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            SNWireLog.sent(request)
            let reader = UploadSender(onProgress: { _, _ in })
            let (data, http) = try await reader.run(request, in: session)
            SNWireLog.received(http, body: data, for: request)
            return (data, http)
        } catch let error as URLError {
            SNWireLog.failed(error, for: request)
            throw transportFailure(error)
        }
    }

    /// How many connections all the downloads together may hold to one host.
    public static let maximumConnectionsPerHost = 6

    /// The one session every download runs on, and the delegate that sorts the
    /// reports out. Progress reaches only a session delegate, so sharing one
    /// session is the only way to have both the reports and one pool.
    private static let router = DownloadRouter()
    static let downloads: URLSession = {
        let configuration = isolated(.default)
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        return URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
    }()

    public func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        do {
            SNWireLog.sent(request)
            let (file, response) = try await Self.router.run(
                request,
                ceiling: DownloadCeiling(limitBytes: limitBytes),
                onProgress: onProgress,
                in: Self.downloads
            )
            SNWireLog.receivedFile(
                response,
                bytes: (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                for: request
            )
            return (file, response)
        } catch let error as URLError {
            SNWireLog.failed(error, for: request)
            throw transportFailure(error)
        }
    }

    /// `uploadTask(with:fromFile:)` streams the body off disk, and the bytes
    /// sent are reported to the session delegate — hence a session of its own.
    /// Uploads come one document at a time, so there is no pool to share.
    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        onProgress: @escaping TransferProgress
    ) async throws -> (Data, HTTPURLResponse) {
        let sender = UploadSender(onProgress: onProgress)
        let session = URLSession(
            configuration: Self.isolated(session.configuration),
            delegate: sender,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            SNWireLog.sent(request)
            let (data, response) = try await sender.run(request, fromFile: file, in: session)
            guard data.count <= Self.bodyLimit else {
                SNWireLog.received(response, body: nil, for: request)
                throw SNError.oversizedResponse(bytes: data.count, limit: Self.bodyLimit)
            }
            SNWireLog.received(response, body: data, for: request)
            return (data, response)
        } catch let error as URLError {
            SNWireLog.failed(error, for: request)
            throw transportFailure(error)
        }
    }
}
