// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// The large-file way into the official cloud's S3, kept apart from the rest of
/// the transfers because it is the one with a conversation of its own.
extension Transfers {
    /// A multipart upload to S3 where the service signs every request.
    ///
    /// Initiate (`POST ?uploads`), each part in turn (`PUT ?partNumber&uploadId`,
    /// eight mebibytes), complete (`POST ?uploadId` with the parts' ETags) — and
    /// before each, `file/s3/auth` with the method, the query, the object's key
    /// and, for the last, the body, answered with an `Authorization` and the
    /// `x-amz-date` it was made for.
    ///
    /// No access token goes to S3, though the official app sends one on the
    /// completion: S3 has no use for it, and it is a credential to the account.
    func multipart(
        _ original: Original,
        to objectURL: URL,
        key: String,
        signer: @escaping S3Signer,
        onProgress: @escaping TransferProgress
    ) async throws {
        let transport = channel.transport
        let initiate = try await signer(S3SigningRequest(method: "POST", params: ["uploads": ""], key: key, body: nil))
        var start = Self.s3Request(objectURL, query: [URLQueryItem(name: "uploads", value: nil)], method: "POST", signed: initiate)
        start.httpBody = Data()
        start.setValue("0", forHTTPHeaderField: "Content-Length")
        // A change, not a read: an initiation whose answer was lost has made an
        // upload, and asking again makes a second one nobody will finish.
        let started = try await withRetry(policy: channel.policy, sleeper: channel.sleeper, retrying: channel.policy.shouldRetryChange) {
            let (data, response) = try await transport.send(start)
            try Self.storageAccepted(response, url: objectURL)
            return data
        }
        guard let uploadID = Self.xmlValue("UploadId", in: started) else {
            throw SNError.malformedResponse("S3 named no upload: \(SNError.shape(of: started))")
        }
        do {
            try await uploadParts(
                original, to: S3Upload(objectURL: objectURL, key: key, uploadID: uploadID), signer: signer, onProgress: onProgress
            )
        } catch {
            // Parts S3 holds for an upload nobody completes are stored, and
            // billed, until a lifecycle rule clears them. The abort is a best
            // effort — the service may not sign a DELETE — and never hides the
            // failure that called for it. Sent from a task of its own: when
            // the failure is a cancellation, a request from this one would be
            // cancelled before it left.
            await Task { await self.abort(objectURL, key: key, uploadID: uploadID, signer: signer) }.value
            throw error
        }
    }

    /// The parts and the completion of an upload S3 has started.
    private func uploadParts(
        _ original: Original,
        to upload: S3Upload,
        signer: S3Signer,
        onProgress: @escaping TransferProgress
    ) async throws {
        let (objectURL, key, uploadID) = (upload.objectURL, upload.key, upload.uploadID)
        let transport = channel.transport

        var parts: [(number: Int, etag: String)] = []
        let count = Int((original.size + Self.chunkSize - 1) / Self.chunkSize)
        for index in 0..<count {
            let number = index + 1
            let offset = Int64(index) * Self.chunkSize
            let length = min(Self.chunkSize, original.size - offset)
            let query = [
                URLQueryItem(name: "partNumber", value: String(number)),
                URLQueryItem(name: "uploadId", value: uploadID),
            ]
            let signed = try await signer(S3SigningRequest(
                method: "PUT", params: ["partNumber": String(number), "uploadId": uploadID], key: key, body: nil
            ))
            let request = Self.s3Request(objectURL, query: query, method: "PUT", signed: signed)
            let slice = try ScratchFile.slice(of: original.file, offset: offset, length: length)
            defer { try? FileManager.default.removeItem(at: slice) }
            let etag = try await withRetry(policy: channel.policy, sleeper: channel.sleeper, retrying: channel.policy.shouldRetry) {
                let (_, response) = try await transport.upload(request, fromFile: slice) { sent, _ in
                    onProgress(offset + min(sent, length), original.size)
                }
                try Self.storageAccepted(response, url: objectURL)
                guard let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
                    throw SNError.malformedResponse("S3 answered part \(number) with no ETag")
                }
                return etag
            }
            parts.append((number, etag))
        }

        // Bare XML, no declaration and no namespace, as the official app sends it.
        let xml = "<CompleteMultipartUpload>"
            + parts.map { "<Part><PartNumber>\($0.number)</PartNumber><ETag>\($0.etag)</ETag></Part>" }.joined()
            + "</CompleteMultipartUpload>"
        let finish = try await signer(S3SigningRequest(method: "POST", params: ["uploadId": uploadID], key: key, body: xml))
        var complete = Self.s3Request(
            objectURL, query: [URLQueryItem(name: "uploadId", value: uploadID)], method: "POST", signed: finish
        )
        complete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        complete.httpBody = Data(xml.utf8)
        // Not retried on a 5xx: S3 may have assembled the object and lost only
        // the answer, and completing twice is an error of its own.
        let (answer, response) = try await transport.send(complete)
        try Self.storageAccepted(response, url: objectURL)
        // S3 is known to answer a completion 200 and put the failure in the body.
        if Self.xmlValue("Code", in: answer) != nil || String(decoding: answer, as: UTF8.self).contains("<Error>") {
            throw SNError.rejected(code: Self.xmlValue("Code", in: answer) ?? "S3", message: Self.xmlValue("Message", in: answer) ?? "")
        }
    }

    /// `DELETE ?uploadId`, signed like the rest; whatever it answers is only
    /// logged.
    private func abort(_ objectURL: URL, key: String, uploadID: String, signer: S3Signer) async {
        do {
            let signed = try await signer(S3SigningRequest(method: "DELETE", params: ["uploadId": uploadID], key: key, body: nil))
            let request = Self.s3Request(
                objectURL, query: [URLQueryItem(name: "uploadId", value: uploadID)], method: "DELETE", signed: signed
            )
            let (_, response) = try await channel.transport.send(request)
            try Self.storageAccepted(response, url: objectURL)
        } catch {
            Log.supernote.notice("an unfinished S3 upload could not be aborted: \(String(describing: error), .public)")
        }
    }

    /// A request to S3 with the signature the service made for it.
    private static func s3Request(_ url: URL, query: [URLQueryItem], method: String, signed: S3Signature) -> URLRequest {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.queryItems = query
        var request = SNRequest.to(parts?.url ?? url, method: method)
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(signed.date, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        return request
    }

    /// The text of the first `<name>` element, for the two or three values an
    /// S3 answer is read for. Not an XML parser, and not meant to be one.
    static func xmlValue(_ name: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

}

/// An upload S3 has started: the object, its key, and the identifier S3 gave it.
private struct S3Upload {
    let objectURL: URL
    let key: String
    let uploadID: String
}
