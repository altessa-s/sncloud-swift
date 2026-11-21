// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The bytes, in both directions, for both file APIs.
///
/// The web API and the device API differ in how a file is named and where it is
/// asked for, and agree entirely on how the bytes travel: down from a signed URL
/// with no token on it, up through whatever `upload/apply` answered — an S3
/// object or a signed form. One copy of that, here, so the two layers cannot
/// drift on a rule about credentials or checksums.
struct Transfers {
    let channel: SNChannel

    /// The ceiling on a download whose size nobody declared. The service
    /// refuses an upload past a gigabyte (`FILE_MAX`), so twice that is no file
    /// it ever stored.
    static let downloadLimit: Int64 = 2 * 1024 * 1024 * 1024

    /// How large one part of a chunked upload to a private cloud is: the eight
    /// mebibytes the tablets use.
    static let chunkSize: Int64 = 8 * 1024 * 1024

    // MARK: - Down

    /// GET a signed URL into a file, held to `limit` and, where one is given,
    /// to `md5`. Whatever fails the checks is removed before the error leaves.
    ///
    /// `range` asks for part of the file; a part has no MD5 of its own to be
    /// held to, so the check is skipped for one.
    func fetch(
        _ url: URL,
        limit: Int64,
        md5 expected: String?,
        range: ClosedRange<Int64>? = nil,
        onProgress: @escaping TransferProgress
    ) async throws -> URL {
        let transport = channel.transport
        var request = SNRequest.to(url)
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        let file = try await withRetry(policy: channel.policy, sleeper: channel.sleeper, retrying: channel.policy.shouldRetry) {
            let (file, response) = try await transport.download(request, limitBytes: limit, onProgress: onProgress)
            do {
                try Self.storageAccepted(response, url: url)
                if let range { try Self.served(range, response: response, file: file) }
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            return file
        }
        guard range == nil, let expected = expected?.lowercased(), !expected.isEmpty else { return file }
        let actual: String
        do {
            actual = try Digests.md5(ofFile: file).md5
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        guard actual == expected else {
            try? FileManager.default.removeItem(at: file)
            throw SNError.checksumMismatch(expected: expected, actual: actual)
        }
        return file
    }

    // MARK: - Up

    /// Put `original`'s bytes where `slot` says, and answer with the name the
    /// server stored them under.
    ///
    /// The response selects the transport with `apiServer`: `"1"` S3, `"0"` Aliyun OSS,
    /// `"private_cloud"` a signed form. An answer without the field — older or
    /// re-implemented servers — is read by which fields it has instead.
    ///
    /// - **S3, up to eight mebibytes** — one PUT of the raw file, signed by the
    ///   service in `upload/apply`'s own answer, the payload left unsigned.
    /// - **S3, larger** — a multipart upload, every request of which the
    ///   service signs through `file/s3/auth` (`signer`).
    /// - **A signed form** — `multipart/form-data`, in one piece, or in
    ///   eight-mebibyte parts when the server offers a part URL.
    /// - **Aliyun OSS** — unsupported.
    func send(
        _ original: Original,
        to slot: UploadSlot,
        signer: S3Signer? = nil,
        server: FormServer? = nil,
        onProgress: @escaping TransferProgress
    ) async throws -> String {
        switch slot.apiServer {
        case "0":
            throw SNError.rejected(code: "OSS", message: "uploads to Aliyun OSS are not supported")
        case "1", nil:
            if let objectURL = slot.objectURL {
                // The object's key is the stored name: the URL's last component,
                // which is what the official app sends back as `innerName`.
                let key = objectURL.lastPathComponent
                if original.size > Self.chunkSize, let signer {
                    try await multipart(original, to: objectURL, key: key, signer: signer, onProgress: onProgress)
                    return key
                }
                if let object = slot.object {
                    try await put(original.file, to: object, onProgress: onProgress)
                    return slot.innerName ?? key
                }
            }
        default:
            break
        }
        if let form = slot.form {
            let stored = try await post(original, to: form.moved(to: server), token: server?.token, onProgress: onProgress)
            guard let stored = stored ?? slot.innerName else {
                throw SNError.malformedResponse("the upload named no stored file")
            }
            return stored
        }
        throw SNError.malformedResponse("upload/apply named nowhere to put the bytes")
    }

    private func put(_ file: URL, to target: UploadSlot.Object, onProgress: @escaping TransferProgress) async throws {
        var request = SNRequest.to(target.url, method: "PUT")
        request.setValue(target.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(target.date, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        let transport = channel.transport
        try await withRetry(policy: channel.policy, sleeper: channel.sleeper, retrying: channel.policy.shouldRetry) {
            let (_, response) = try await transport.upload(request, fromFile: file, onProgress: onProgress)
            try Self.storageAccepted(response, url: target.url)
        }
    }

    /// A form, whole or in parts. Answers with the name the server stored the
    /// file under, where it says one.
    private func post(
        _ original: Original,
        to form: UploadSlot.Form,
        token: String?,
        onProgress: @escaping TransferProgress
    ) async throws -> String? {
        let size = original.size
        guard size > Self.chunkSize, let parts = form.partURL else {
            let answer = try await send(original, 0..<size, to: (form.url, token), as: FormAnswer.self) {
                onProgress(min($0, size), size)
            }
            // One server answers with the MD5 it computed, another with null; a
            // null is no disagreement.
            if let echoed = answer.md5?.lowercased(), !echoed.isEmpty, echoed != original.md5 {
                throw SNError.checksumMismatch(expected: original.md5, actual: echoed)
            }
            return answer.innerName
        }

        // `{milliseconds}_{uuid}`, the tablets' shape.
        let uploadID = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.lowercased())"
        let count = Int((size + Self.chunkSize - 1) / Self.chunkSize)
        for index in 0..<count {
            let offset = Int64(index) * Self.chunkSize
            let length = min(Self.chunkSize, size - offset)
            guard var target = URLComponents(url: parts, resolvingAgainstBaseURL: false) else {
                throw SNError.malformedResponse("part upload URL")
            }
            target.queryItems = (target.queryItems ?? []) + [
                URLQueryItem(name: "uploadId", value: uploadID),
                URLQueryItem(name: "partNumber", value: String(index + 1)),
                URLQueryItem(name: "totalChunks", value: String(count)),
            ]
            guard let url = target.url else { throw SNError.malformedResponse("part upload URL") }
            let answer = try await send(original, offset..<(offset + length), to: (url, token), as: PartAnswer.self) {
                onProgress(offset + min($0, length), size)
            }
            if let echoed = answer.chunkMd5?.lowercased(), !echoed.isEmpty {
                let actual = try Digests.md5(ofFile: original.file, offset: offset, length: length).md5
                guard echoed == actual else { throw SNError.checksumMismatch(expected: actual, actual: echoed) }
            }
        }
        return nil
    }

    /// One form to one signed URL, and its answer opened.
    ///
    /// With the access token when `token` is given — which is only ever for a
    /// private cloud's own `/api/oss/upload`, on the configured host: Ratta's
    /// server answers that endpoint 401 without it, signature or not, and the
    /// official app sends it.
    private func send<Answer: Decodable>(
        _ original: Original,
        _ range: Range<Int64>,
        to target: (url: URL, token: String?),
        as answer: Answer.Type,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Answer {
        let form = try MultipartFile.write(
            from: original.file,
            offset: range.lowerBound,
            length: range.upperBound - range.lowerBound,
            name: original.name
        )
        defer { try? FileManager.default.removeItem(at: form.url) }
        let url = target.url
        var request = SNRequest.to(url, method: "POST")
        if let token = target.token { request.setValue(token, forHTTPHeaderField: SNRequest.accessTokenHeader) }
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let transport = channel.transport
        return try await withRetry(policy: channel.policy, sleeper: channel.sleeper, retrying: channel.policy.shouldRetry) {
            // What `URLSession` counts is the form, framing and all; what the
            // caller is told is the file's own bytes.
            let header = form.headerLength
            let (data, response) = try await transport.upload(request, fromFile: form.url) { sent, _ in
                progress(max(0, sent - header))
            }
            try Self.storageAccepted(response, url: url)
            return try SNChannel.open(data, as: Answer.self)
        }
    }

    /// Whether a ranged answer is the range that was asked for.
    ///
    /// A part has no hash of its own, so this is the whole of its check, and it
    /// is strict: 206 and nothing else — a server that ignores `Range` answers
    /// 200 with the whole file, which is not the part the caller will treat it
    /// as; a `Content-Range` that parses and starts where the request did; and
    /// a body exactly as long as that header says. A shorter range than asked
    /// for is accepted only where it ends at the end of the file, which is
    /// what a range running past the end gets.
    private static func served(_ range: ClosedRange<Int64>, response: HTTPURLResponse, file: URL) throws {
        guard response.statusCode == 206 else {
            throw SNError.malformedResponse("asked for bytes \(range), answered \(response.statusCode) instead of 206")
        }
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let declared = ContentRange(header)
        else { throw SNError.malformedResponse("asked for bytes \(range), the answer named no range it served") }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        let reachesEnd = declared.total.map { declared.last == $0 - 1 } ?? false
        guard declared.first == range.lowerBound,
              declared.last <= range.upperBound,
              declared.last == range.upperBound || reachesEnd,
              size == declared.last - declared.first + 1
        else {
            throw SNError.malformedResponse("asked for bytes \(range), served \(header) in \(size) bytes")
        }
    }

    /// A storage endpoint's answer, checked. A refusal there is about the
    /// signature, never the session: a 401 from storage must not log the
    /// person out.
    static func storageAccepted(_ response: HTTPURLResponse, url: URL) throws {
        guard let refusal = SNError.fromHTTP(response) else { return }
        if case .sessionExpired = refusal { throw SNError.http(status: 401, path: url.path()) }
        throw refusal
    }
}

/// `Content-Range: bytes <first>-<last>/<total>`, with `*` for a total the
/// server does not know.
struct ContentRange: Equatable {
    let first: Int64
    let last: Int64
    let total: Int64?

    init?(_ header: String) {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = text.dropFirst("bytes ".count)
        let halves = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let ends = halves[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard ends.count == 2, let first = Int64(ends[0]), let last = Int64(ends[1]), first >= 0, last >= first
        else { return nil }
        let total: Int64?
        if halves[1] == "*" {
            total = nil
        } else {
            guard let value = Int64(halves[1]), value > last else { return nil }
            total = value
        }
        self.first = first
        self.last = last
        self.total = total
    }
}

/// Where a private cloud's upload form goes, and the token it wants: the
/// configured server, never whatever host an answer named.
struct FormServer: Sendable {
    let host: URL
    let token: String
}

/// One request the service is asked to sign for S3: `file/s3/auth`'s body.
struct S3SigningRequest: Sendable {
    let method: String
    let params: [String: String]
    let key: String
    let body: String?
}

/// What `file/s3/auth` answers with.
struct S3Signature: Sendable, Decodable {
    let authorization: String
    let date: String

    enum CodingKeys: String, CodingKey {
        case authorization = "s3Authorization"
        case date = "xamzDate"
    }
}

/// Who signs a multipart upload's requests: the session, through the apps' host.
typealias S3Signer = @Sendable (S3SigningRequest) async throws -> S3Signature

/// The file being uploaded, and what was measured of it before anything went
/// out.
struct Original {
    let file: URL
    let name: String
    let size: Int64
    let md5: String

    static func measure(_ file: URL, name: String) throws -> Original {
        let (md5, size) = try Digests.md5(ofFile: file)
        return Original(file: file, name: name, size: size, md5: md5)
    }
}

/// What `upload/apply` answers, read leniently: the two kinds of server spell
/// the same fields differently, and one of them is not consistent with itself
/// (`xAmzDate` in its own model, `xamzDate` on the wire). The web and device
/// variants of `apply` answer the same shape.
struct UploadSlot: Decodable, Sendable {
    /// An object PUT, signed by the service.
    struct Object: Sendable {
        let url: URL
        let authorization: String
        let date: String?
    }

    /// A signed form POST, and where its parts go.
    struct Form: Sendable {
        let url: URL
        let partURL: URL?

        /// The same form on the configured server's own scheme, host and port,
        /// as the official app rewrites it: the path and the signed query are
        /// the server's, the address is ours. A server behind a proxy has been
        /// seen to name its internal port here, which no client can reach.
        func moved(to server: FormServer?) -> Form {
            guard let server else { return self }
            return Form(url: url.moved(onto: server.host), partURL: partURL.map { $0.moved(onto: server.host) })
        }
    }

    let object: Object?
    /// The S3 object the bytes are for, signed or not: a multipart upload
    /// needs it even where the answer carries no signature for a single PUT.
    let objectURL: URL?
    /// Which way the bytes go, as the official app reads it. See `send`.
    let apiServer: String?
    /// Opaque, and handed back to `file/s3/auth` as it came.
    let fileServer: WireEcho?
    let form: Form?
    let innerName: String?

    private enum Keys: String, CodingKey {
        // `s3Url` is the digests' handwriting apply's spelling of `url`.
        case url, s3Url, s3Authorization, xamzDate, xAmzDate, fullUploadUrl, partUploadUrl, innerName, apiServer, fileServer
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String? {
            guard let value = try? container.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
            return value
        }
        func url(_ key: Keys) -> URL? { text(key).flatMap(URL.init(string:)) }
        if let target = url(.url) ?? url(.s3Url), let authorization = text(.s3Authorization) {
            object = Object(url: target, authorization: authorization, date: text(.xamzDate) ?? text(.xAmzDate))
        } else {
            object = nil
        }
        form = url(.fullUploadUrl).map { Form(url: $0, partURL: url(.partUploadUrl)) }
        objectURL = url(.url) ?? url(.s3Url)
        switch try? container.decodeIfPresent(WireEcho.self, forKey: .apiServer) {
        case .number(let number): apiServer = String(number)
        case .text(let text): apiServer = text
        case nil: apiServer = nil
        }
        fileServer = try? container.decodeIfPresent(WireEcho.self, forKey: .fileServer)
        innerName = text(.innerName)
    }
}

private struct FormAnswer: Decodable {
    let innerName: String?
    let md5: String?
}

private struct PartAnswer: Decodable {
    let chunkMd5: String?
}

extension URL {
    /// The same URL on `host`'s scheme, host and port: the path and the signed
    /// query are the server's, the address is the one this client was given.
    func moved(onto host: URL) -> URL {
        guard var parts = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: host, resolvingAgainstBaseURL: false)
        else { return self }
        parts.scheme = target.scheme
        parts.host = target.host
        parts.port = target.port
        return parts.url ?? self
    }

    /// A link the server made to its own storage — `/api/oss/download?…` on a
    /// private cloud — moved onto `host`, as the official app moves its form
    /// URLs: the server builds these from whatever address it saw, and behind
    /// a proxy that is one no client can reach. A link elsewhere — S3 on the
    /// official cloud — is left as it is.
    func servedFrom(_ host: URL) -> URL {
        path().hasPrefix("/api/oss/") ? moved(onto: host) : self
    }
}
