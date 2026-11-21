// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog
import Synchronization

/// The wire, written out: what went to the service and what came back.
///
/// Off unless asked for. The protocol is unofficial and its failures are rarely
/// a stack trace — a 200 with `success: false` and a code nobody catalogued, a
/// header nobody documented — and the only way to see one is to look at the
/// exchange itself.
///
/// ```
/// SNCLOUD_WIRE_LOG=headers   the request and response lines, and every header
/// SNCLOUD_WIRE_LOG=bodies    the same, plus bodies that are text, JSON or XML
/// ```
///
/// **What never reaches it.** Credentials are masked wherever they appear —
/// `x-access-token`, the XSRF token, cookies, an upload's S3 `Authorization` —
/// through `RedactLog`'s `.secret` tag. A URL's query is dropped and counted,
/// because a signed storage URL carries its signature there. The login calls'
/// bodies carry a password digest one way and the access token the other, and
/// are never printed at any level — only counted.
///
/// **What does, at `bodies`.** The user's own words: a listing holds the names
/// of every file in a folder. That is the point of the level, and it is why it
/// is a second word rather than the same switch.
public enum SNWireLog {
    /// Frozen, for the reason given on `SNError`.
    @frozen
    public enum Level: String, Sendable, CaseIterable {
        case off
        case headers
        case bodies
    }

    /// What the environment asked for, read once.
    public static let level = Level(named: ProcessInfo.processInfo.environment[variable])

    public static let variable = "SNCLOUD_WIRE_LOG"

    static var isOn: Bool { level != .off }

    // MARK: - What is written

    static func sent(_ request: URLRequest) {
        guard isOn else { return }
        announceOnce()
        for line in describe(request, level: level) { write(line) }
    }

    static func received(_ response: HTTPURLResponse, body: Data?, for request: URLRequest) {
        guard isOn else { return }
        for line in describe(response, body: body, for: request, level: level) { write(line) }
    }

    /// A body that never comes into memory: its size is all that can honestly
    /// be said about it.
    static func receivedFile(_ response: HTTPURLResponse, bytes: Int64, for request: URLRequest) {
        guard isOn else { return }
        for line in describe(response, body: nil, for: request, level: level) { write(line) }
        write("  ← body: \(bytes, .public) bytes into a file")
    }

    static func redirected(from response: HTTPURLResponse, to request: URLRequest) {
        guard isOn else { return }
        write("→→ \(response.statusCode, .public) redirect to \(safe(request.url), .public)")
        for line in describe(request, level: level) { write(line) }
    }

    /// The error by its domain and code only. A `URLError`'s description
    /// carries the failing URL whole — a signed storage URL's query, which is
    /// a credential, included.
    static func failed(_ error: any Error, for request: URLRequest) {
        guard isOn else { return }
        let failure = Self.failure(error)
        write("←! \(method(of: request), .public) \(safe(request.url), .public) — \(failure, .public)")
    }

    static func failure(_ error: any Error) -> String {
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }

    // MARK: - What the lines say

    /// The request as lines. Pure, so that what is written can be held to
    /// without a server: this is the half where a mistake is a leaked token
    /// rather than a wrong answer.
    static func describe(_ request: URLRequest, level: Level) -> [LogMessage] {
        guard level != .off else { return [] }
        var lines: [LogMessage] = [
            "→ \(method(of: request), .public) \(safe(request.url), .public)",
        ]
        lines += headerLines(request.allHTTPHeaderFields, arrow: "  →")
        if let body = bodyLine(
            request.httpBody,
            contentType: request.value(forHTTPHeaderField: "content-type"),
            of: request,
            arrow: "  →",
            level: level
        ) {
            lines.append(body)
        }
        return lines
    }

    static func describe(
        _ response: HTTPURLResponse,
        body: Data?,
        for request: URLRequest,
        level: Level
    ) -> [LogMessage] {
        guard level != .off else { return [] }
        var lines: [LogMessage] = [
            "← \(response.statusCode, .public) \(method(of: request), .public) \(safe(request.url), .public)",
        ]
        lines += headerLines(
            response.allHeaderFields.reduce(into: [String: String]()) { headers, field in
                headers[String(describing: field.key)] = String(describing: field.value)
            },
            arrow: "  ←"
        )
        if let body = bodyLine(
            body,
            contentType: response.value(forHTTPHeaderField: "content-type"),
            of: request,
            arrow: "  ←",
            level: level
        ) {
            lines.append(body)
        }
        return lines
    }

    /// The one line about a body, in either direction, or none: a credential
    /// exchange's body is counted and never printed; a body the level asks for
    /// and a person can read is printed; anything else is counted.
    static func bodyLine(
        _ body: Data?,
        contentType: String?,
        of request: URLRequest,
        arrow: String,
        level: Level
    ) -> LogMessage? {
        if carriesCredentialBody(request.url) {
            guard let body, !body.isEmpty else { return nil }
            return "\(arrow, .public) body: \(body.count, .public) bytes (credential exchange — never printed)"
        }
        if let text = bodyText(body, contentType: contentType, level: level) {
            return "\(arrow, .public) body: \(text, .public)"
        }
        guard let body else { return nil }
        return "\(arrow, .public) body: \(body.count, .public) bytes"
    }

    static func bodyText(_ data: Data?, contentType: String?, level: Level) -> String? {
        guard level == .bodies, let data, !data.isEmpty else { return nil }
        guard isReadable(contentType) else { return nil }
        // JSON is printed redacted or not at all: an answer to `upload/apply`
        // carries an S3 signature and a signed URL, an answer to
        // `download/url` a signed URL, and none of the three is a header that
        // the masking above would see.
        if contentType?.lowercased().contains("json") == true {
            guard let redacted = redactedJSON(data) else {
                return "\(data.count) bytes of JSON that does not parse (not printed)"
            }
            return redacted
        }
        guard let text = String(data: data.prefix(bodyLimit), encoding: .utf8) else { return nil }
        let tail = data.count > bodyLimit ? "… (\(data.count) bytes in all)" : ""
        return text.replacingOccurrences(of: "\n", with: "\n     ") + tail
    }

    /// A JSON body with every credential in it replaced: fields named like
    /// one, and any string that is a URL with a query — a signed URL is a
    /// credential whatever its field is called.
    static func redactedJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let cleaned = redact(object, key: nil)
        guard let out = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8)
        else { return nil }
        guard text.utf8.count > bodyLimit else { return text }
        // Decoded with replacement, so a cut through a multi-byte character
        // costs one character and never the cap.
        return String(decoding: text.utf8.prefix(bodyLimit), as: UTF8.self) + "… (\(text.utf8.count) bytes in all)"
    }

    private static func redact(_ value: Any, key: String?) -> Any {
        if let key, isSecret(key: key), !(value is NSNull) { return "<redacted>" }
        switch value {
        case let object as [String: Any]:
            return object.reduce(into: [String: Any]()) { $0[$1.key] = redact($1.value, key: $1.key) }
        case let array as [Any]:
            return array.map { redact($0, key: key) }
        case let text as String:
            if let url = URL(string: text), url.scheme != nil, url.query != nil { return safe(url) }
            return text
        default:
            return value
        }
    }

    /// Body fields that are credentials, matched like headers are: by
    /// substring, so that a field nobody has met yet is masked rather than
    /// missed. `validCode` is the code from the email, `sign` the request for
    /// one, `password` the digest.
    private static func isSecret(key: String) -> Bool {
        let name = key.lowercased()
        return secretFields.contains { name.contains($0) }
            || ["password", "sign", "validcode"].contains { name.contains($0) }
    }

    /// The calls whose bodies are credentials, in one direction or the other: a
    /// login sends a password digest and answers with the access token; the
    /// verification calls send the signing token and answer with a code key or
    /// the access token; `query/token` answers with the access token.
    static func carriesCredentialBody(_ url: URL?) -> Bool {
        guard let path = url?.path else { return false }
        return credentialPaths.contains { path.contains($0) }
    }

    private static let credentialPaths = [
        "/user/account/login",
        "/user/sms/login",
        "/user/query/token",
        "/user/validcode",
        "/validcode/send",
        "/user/mail/validcode",
        "/user/check/validcode",
    ]

    static func isReadable(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased() else { return false }
        return type.hasPrefix("text/") || type.contains("json") || type.contains("xml")
    }

    /// Headers, with anything that could be a credential masked. A denylist by
    /// substring, because the field is the server's to name.
    static func headerLines(_ headers: [String: String]?, arrow: String) -> [LogMessage] {
        (headers ?? [:])
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { field, value in headerLine(field: field, value: value, arrow: arrow) }
    }

    static func headerLine(field: String, value: String, arrow: String) -> LogMessage {
        guard tag(for: field) == .secret else {
            // A `Location` to signed storage carries its signature in the
            // query, like any other URL here.
            if let url = URL(string: value), url.scheme != nil, url.query != nil {
                return "\(arrow, .public) \(field, .public): \(safe(url), .public)"
            }
            return "\(arrow, .public) \(field, .public): \(value, .public)"
        }
        return "\(arrow, .public) \(field, .public): \(value, .secret)"
    }

    /// What may be done with a header's value, decided by its name.
    static func tag(for field: String) -> LogMessage.Tag {
        let name = field.lowercased()
        return secretFields.contains(where: { name.contains($0) }) ? .secret : .public
    }

    /// A URL without its query. A signed storage URL carries the signature
    /// there.
    static func safe(_ url: URL?) -> String {
        guard let url else { return "<no url>" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let count = parts.queryItems?.count ?? 0
        parts.query = nil
        let base = parts.string ?? url.absoluteString
        return count == 0 ? base : "\(base) (+\(count) query items)"
    }

    private static func method(of request: URLRequest) -> String {
        request.httpMethod ?? "GET"
    }

    /// `channel` is on the list because the official app's `channel` header
    /// starts with the access token itself.
    private static let secretFields = ["authorization", "token", "cookie", "signature", "secret", "xsrf", "channel"]

    static let bodyLimit = 4096

    // MARK: - Where the lines go

    private static func write(_ line: LogMessage) {
        Log.supernote.debug(line)
    }

    private static let announced = Mutex(false)

    private static func announceOnce() {
        let first = announced.withLock { seen -> Bool in
            defer { seen = true }
            return !seen
        }
        guard first else { return }
        write("wire log on (\(level.rawValue, .public)): credentials are masked, query strings dropped")
        if level == .bodies {
            write("wire log: bodies include file and folder names")
        }
    }
}

// Equality spelled out rather than synthesised; see `SNError`.
extension SNWireLog.Level {
    public static func == (lhs: SNWireLog.Level, rhs: SNWireLog.Level) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension SNWireLog.Level {
    /// What the variable means, including the spellings a person actually types.
    init(named value: String?) {
        switch value?.lowercased() {
        case "headers", "1", "true", "yes", "on": self = .headers
        case "bodies", "body", "full", "2": self = .bodies
        default: self = .off
        }
    }
}
