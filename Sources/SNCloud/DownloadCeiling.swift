// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The ceiling one download is held to, and the whole of the rule.
///
/// A type of its own because the delegate that applies it can only be reached
/// with a server on the other end, and the rule is the part worth asking
/// questions of: what it does with a length nobody declared, and which of the
/// two numbers it believes.
struct DownloadCeiling: Sendable {
    let limitBytes: Int64

    /// Why this download must stop, or `nil` to let it carry on.
    ///
    /// `expected` is the server's own declaration, and refusing on it is free —
    /// the refusal lands on the first report. `written` is what actually
    /// arrived, and it is the one that cannot be talked round: a response
    /// declaring a kilobyte and sending a gigabyte is exactly what a ceiling is
    /// for. An undeclared length arrives negative and says nothing either way.
    func refusal(written: Int64, expected: Int64) -> SNError? {
        let over = max(written, expected)
        guard over > limitBytes else { return nil }
        return .oversizedResponse(bytes: Int(clamping: over), limit: Int(clamping: limitBytes))
    }
}
