// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Scratch files for downloads. One place, so that the names do not spread
/// through the code and so that ownership of the file is obvious: whoever
/// received the URL is the one who cleans up.
///
/// Internal, and a copy of `RMCloud`'s: thirty lines are not worth a shared
/// dependency, and a public spelling would collide in any module that sees both.
enum ScratchFile {
    /// Where the files go: the process temp directory, unless a task — a test
    /// that needs to see only its own — names another for its length.
    @TaskLocal static var directory: URL?

    /// A free path in the temp directory. Does not create a file.
    static func location() -> URL {
        (directory ?? FileManager.default.temporaryDirectory).appending(path: UUID().uuidString)
    }

    static func write(_ data: Data) throws -> URL {
        let url = location()
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `length` bytes of `source` from `offset`, as a file of their own: one
    /// part of a multipart upload, streamed off disk like a whole file.
    static func slice(of source: URL, offset: Int64, length: Int64) throws -> URL {
        let url = location()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: url) } }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            guard let chunk = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !chunk.isEmpty else {
                throw SNError.malformedResponse("the file ended before its declared size")
            }
            try output.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        finished = true
        return url
    }

    /// Take somebody else's temporary file for ourselves. A move is cheaper
    /// than a copy, but is impossible across volumes — there a copy remains,
    /// cleaning up after itself.
    static func claim(_ file: URL) throws -> URL {
        let url = location()
        let manager = FileManager.default
        do {
            try manager.moveItem(at: file, to: url)
        } catch {
            try manager.copyItem(at: file, to: url)
            try? manager.removeItem(at: file)
        }
        return url
    }
}
