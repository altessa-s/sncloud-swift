// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import SNCloud
import Synchronization

/// The secrets, in a file only this user can read.
///
/// Not the Keychain, on purpose: every rebuild of a command-line tool is a new
/// code signature, and the Keychain answers each one with a dialog. A tool run
/// a hundred times while a protocol is checked cannot ask a hundred times. The
/// file is `0600` in a `0700` directory, holds the access token, the account
/// and the installation's UUID — never the password — and `snctl forget`
/// removes the first two.
///
/// `SNCTL_HOME` moves it; the default is `~/.config/snctl`.
///
/// **One file per server.** A token is a credential to the server that issued
/// it, and `--private` points the tool somewhere else entirely: one shared file
/// would carry the official cloud's token — and the `channel` header built
/// from it — to whatever host was named next. The official cloud keeps
/// `secrets.json`; any other server gets `secrets-<host>[-<port>].json`.
final class FileSecrets: SNSecretStoring {
    let file: URL
    private let lock = Mutex(())

    init(for endpoints: SNEndpoints, home given: URL? = nil) throws {
        let home = given
            ?? ProcessInfo.processInfo.environment["SNCTL_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/snctl")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        file = home.appending(path: Self.fileName(for: endpoints))
    }

    /// `secrets.json` for the official cloud; for any other server, its host
    /// to read and a hash of everything that tells two servers apart — scheme,
    /// host, port with its default spelled out, path — so that `nas:8080` and
    /// `nas-8080`, or `http://nas` and `https://nas`, never share a token.
    static func fileName(for endpoints: SNEndpoints) -> String {
        guard endpoints != .official else { return "secrets.json" }
        let url = endpoints.appHost
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host()?.lowercased() ?? ""
        let port = url.port ?? (scheme == "http" ? 80 : 443)
        let identity = "\(scheme)\n\(host)\n\(port)\n\(url.path())"
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let readable = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return "secrets-\(readable.isEmpty ? "server" : readable)-\(hash).json"
    }

    func secret(_ which: SNSecret) throws -> String? {
        try lock.withLock { _ in try read()[which.rawValue] }
    }

    func keep(_ value: String, as which: SNSecret) throws {
        try lock.withLock { _ in
            var all = try read()
            all[which.rawValue] = value
            try write(all)
        }
    }

    func discard(_ which: SNSecret) throws {
        try lock.withLock { _ in
            var all = try read()
            all[which.rawValue] = nil
            try write(all)
        }
    }

    private func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    /// Atomically, and never readable by anybody else for a moment: the
    /// temporary file is created `0600` by `open` itself, filled, flushed and
    /// renamed over the old one. Writing first and `chmod`-ing after — which
    /// `Data.write(options: .atomic)` would make the only choice — leaves the
    /// token world-readable between the rename and the `chmod`, on every write.
    private func write(_ all: [String: String]) throws {
        let data = try JSONEncoder().encode(all)
        let temporary = file.deletingLastPathComponent().appending(path: ".secrets-\(UUID().uuidString).json")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, file.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(temporary.path)
            throw POSIXError(code)
        }
    }
}
