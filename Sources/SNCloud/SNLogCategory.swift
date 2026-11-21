// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import RedactLog

/// The channel this package writes on.
///
/// Not `cloud`: that one is `RMCloud`'s, and a host that links both protocols
/// would otherwise get two declarations of `LogCategory.cloud` — ambiguous at
/// every call site, and one stream for two services that fail differently.
///
/// The raw value is a contract with whoever reads a log:
/// `log stream --predicate 'category == "supernote"'`.
public extension LogCategory {
    static let supernote = LogCategory(rawValue: "supernote")
}

/// Sugar: every line in this package reads `Log.supernote.debug(…)`.
public extension Log {
    static var supernote: LogChannel { logger(.supernote) }
}
