// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

/// The hashes the protocol is built on: MD5 for content and for the stored
/// password, SHA-256 for everything that is signed.
///
/// MD5 is not chosen here — it is the service's. It names a file's content in
/// every listing and every upload, and it is what the server keeps of a
/// password. `Insecure` is CryptoKit's word for it, and it is the right one;
/// nothing in this package relies on MD5 resisting anybody.
enum Digests {
    /// What the login sends in place of the password.
    ///
    /// `hex(SHA256(hex(MD5(password)) + randomCode))`, lowercase throughout.
    /// The server keeps `MD5(password)` and does the same sum with the salt it
    /// just handed out, which it then forgets: a digest is good for one login
    /// and no more. The challenge's timestamp travels beside it and is not part
    /// of the sum. Three independent clients agree on every step of this.
    static func password(_ password: String, salt randomCode: String) -> String {
        sha256(md5(Data(password.utf8)) + randomCode)
    }

    static func md5(_ data: Data) -> String {
        hex(Insecure.MD5.hash(data: data))
    }

    static func sha256(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// The MD5 of a file and its length, read in slices: a document runs to a
    /// gigabyte, and memory is no place for it.
    static func md5(ofFile file: URL) throws -> (md5: String, size: Int64) {
        try md5(ofFile: file, offset: 0, length: .max)
    }

    /// The MD5 of `length` bytes of a file from `offset` — one part of a
    /// chunked upload, which the server answers with the MD5 it computed —
    /// and how many bytes there were, which is fewer at the end of the file.
    static func md5(ofFile file: URL, offset: Int64, length: Int64) throws -> (md5: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var hasher = Insecure.MD5()
        var size: Int64 = 0
        while size < length,
              let slice = try handle.read(upToCount: Int(min(Int64(sliceSize), length - size))),
              !slice.isEmpty {
            hasher.update(data: slice)
            size += Int64(slice.count)
        }
        return (hex(hasher.finalize()), size)
    }

    static let sliceSize = 1024 * 1024

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The one claim this package reads out of an access token: when it dies.
///
/// The token is a JWT, and its payload is base64 in the middle of it. Nothing
/// here checks the signature — that is the server's, and this client could not
/// check it anyway. What it buys is a session that knows it is over without
/// spending a request to be told.
enum AccessTokenClaims {
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URL(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let raw = object["exp"]
        else { return nil }
        let number: Double? = switch raw {
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
        guard var seconds = number, seconds > 0 else { return nil }
        // One client guards against milliseconds here, and so does this one: a
        // value past 1e11 seconds is the year 5138.
        if seconds > 1e11 { seconds /= 1000 }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func base64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
