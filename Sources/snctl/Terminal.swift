// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Darwin
import Foundation
import RedactLog

/// The terminal: what is asked of the person running the tool, and where the
/// commentary goes.
enum Terminal {
    /// A password, read from the terminal itself with echo off — never from an
    /// argument, where it would land in the shell's history and the process
    /// table, and never from standard input, where a pipe would carry it.
    static func password(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        guard let read = readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) else { return nil }
        let password = String(cString: read)
        // The C buffer is cleared; the Swift string made from it cannot be —
        // Swift offers no way to scrub a string's storage — and lives until the
        // login that needs it is done.
        for index in buffer.indices { buffer[index] = 0 }
        return password.isEmpty ? nil : password
    }

    /// A password from a file only its owner can read — for a test bench,
    /// where nobody is at the terminal. The file is `password=…` on a line of
    /// its own, or the password alone; one readable by anybody else is refused
    /// rather than used.
    static func password(fromFile path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let mode = attributes[.posixPermissions] as? Int, mode & 0o077 != 0 {
            SNCtl.fail("\(url.path) is readable by others (mode \(String(mode, radix: 8))): chmod 600 it first")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let value = lines.first { $0.hasPrefix("password=") }.map { String($0.dropFirst("password=".count)) }
            ?? lines.first ?? ""
        guard !value.isEmpty else { SNCtl.fail("\(url.path) holds no password") }
        return value
    }

    /// A line typed at the terminal, with echo on: an emailed code.
    static func line(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard let read = readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_ON | RPP_REQUIRE_TTY) else { return nil }
        let text = String(cString: read).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Commentary, on standard error: the answer of a command can be piped
    /// into a file, and its commentary must not land there.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// The package's log lines — the wire log among them — on standard error,
/// with secrets masked by `RedactLog`'s own masker.
struct StandardErrorSink: LogSink {
    let minimum: LogLevel
    private let format = MessageFormat()

    func accepts(_ level: LogLevel, in category: LogCategory) -> Bool {
        level >= minimum
    }

    func write(_ entry: LogEntry) {
        FileHandle.standardError.write(Data((format.format(entry) + "\n").utf8))
    }
}
