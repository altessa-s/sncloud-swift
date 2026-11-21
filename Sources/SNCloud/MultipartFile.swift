// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A `multipart/form-data` body with one part, `file`, written to disk.
///
/// A private cloud takes an upload's bytes as a form, and a form around a
/// gigabyte is not built in memory: the body is a scratch file — the header,
/// the slice of the original, the trailer — that `upload(fromFile:)` streams.
/// The caller owns the file and removes it.
struct MultipartFile {
    let url: URL
    let contentType: String
    /// The bytes before the file's own: what a count of bytes sent has to
    /// get past before any of the file has gone.
    let headerLength: Int64

    /// The form around `length` bytes of `source` from `offset`, under the
    /// file name `name`.
    static func write(
        from source: URL,
        offset: Int64 = 0,
        length: Int64,
        name: String,
        boundary: String = "SNCloud-\(UUID().uuidString)"
    ) throws -> MultipartFile {
        let url = ScratchFile.location()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Removed on any way out but success: a source that cannot be opened,
        // one shorter than declared, a full disk.
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: url) } }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        // A quote or a line break in a file name would end the header early;
        // nothing the service stores needs either.
        let safeName = name.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let head = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        let headBytes = Data(head.utf8)
        try output.write(contentsOf: headBytes)

        try input.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            let want = Int(min(remaining, Int64(Digests.sliceSize)))
            guard let slice = try input.read(upToCount: want), !slice.isEmpty else {
                throw SNError.malformedResponse("the file ended before its declared size")
            }
            try output.write(contentsOf: slice)
            remaining -= Int64(slice.count)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        finished = true
        return MultipartFile(
            url: url,
            contentType: "multipart/form-data; boundary=\(boundary)",
            headerLength: Int64(headBytes.count)
        )
    }
}
