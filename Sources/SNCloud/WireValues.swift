// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

// The service's scalars, read the way they actually arrive.
//
// The server is Java, and Jackson coerces liberally on the way in and writes
// whatever the field happened to be on the way out. So the same value is a
// number in one answer and a string in the next: an identifier is a 64-bit
// snowflake sent as `"819922212654940160"`, a timestamp is milliseconds sent as
// a number or as a string, a flag is `"Y"` or `"N"`. A strict `Codable` would
// fail on the first answer that disagreed with the last one; these accept every
// spelling that has been seen and refuse the rest.

/// A 64-bit integer from a number or a string.
///
/// Never through `Double`: a snowflake has eighteen digits and a `Double` keeps
/// fifteen, so a lenient decoder that went through one would hand back the
/// identifier of a different file.
struct WireInt64: Decodable, Sendable, Equatable {
    let value: Int64

    init(_ value: Int64) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            value = number
            return
        }
        let text = try container.decode(String.self).trimmingCharacters(in: .whitespaces)
        guard let number = Int64(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an integer: \(text)")
        }
        value = number
    }
}

/// `"Y"`/`"N"`, and a JSON bool where the service sends one.
struct WireFlag: Decodable, Sendable, Equatable {
    let value: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            value = flag
            return
        }
        value = try container.decode(String.self).uppercased() == "Y"
    }
}

/// A scalar the service hands out and expects back exactly as it was: the
/// login challenge's `timestamp`, which arrives as a number on the live service
/// and as a string from one re-implementation, and is checked on the way back.
/// Echoing it in the other form is a coercion nobody has tested, so it is not
/// made.
enum WireEcho: Codable, Sendable, Equatable {
    case number(Int64)
    case text(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .text(let text): try container.encode(text)
        }
    }
}

extension Date {
    /// Milliseconds since the epoch, the service's one unit of time.
    var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

extension KeyedDecodingContainer {
    /// A millisecond timestamp, as a number or a string; `nil` for anything
    /// else. One specification calls these date-time strings and every client
    /// that has talked to the service reads milliseconds — so a value that is
    /// neither is dropped rather than allowed to fail a whole listing.
    func milliseconds(_ key: Key) -> Date? {
        guard let raw = try? decodeIfPresent(WireInt64.self, forKey: key) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(raw.value) / 1000)
    }

    /// A `java.util.Date` as the service writes it: milliseconds on the live
    /// cloud, an ISO string — `2000-01-01T00:00:00.000+0000` — from Ratta's
    /// own server. `nil` for anything else.
    func instant(_ key: Key) -> Date? {
        if let date = time(key) { return date }
        guard let text = self.text(key) else { return nil }
        return javaDateFormatters.lazy.compactMap { $0.date(from: text) }.first
    }

    /// The same, with `0` read as no time at all: the service writes it where
    /// a column may not be null — a task with no due date has `dueTime: 0`.
    func time(_ key: Key) -> Date? {
        guard let date = milliseconds(key), date.timeIntervalSince1970 != 0 else { return nil }
        return date
    }

    /// A string, with an empty one read as none — the service writes `""` and
    /// `null` for the same absence.
    func text(_ key: Key) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
        return value
    }

    /// An integer from a number or a string; `nil` for anything else.
    func integer(_ key: Key) -> Int64? {
        (try? decodeIfPresent(WireInt64.self, forKey: key))?.value
    }

    /// `"Y"`/`"N"` or a bool; `nil` for anything else.
    func flag(_ key: Key) -> Bool? {
        (try? decodeIfPresent(WireFlag.self, forKey: key))?.value
    }
}

/// The spellings Jackson gives a `Date`, with and without the milliseconds —
/// made once: a listing reads one per entry. Configured here and only read
/// after, which is what makes a shared `DateFormatter` safe.
private let javaDateFormatters: [DateFormatter] = [
    "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss",
].map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter
}

extension Array {
    /// One element per identifier, the **last** one where a page listing
    /// handed the same row twice — which offset paging does when a row changes
    /// mid-listing and moves to a later page — in the order they came.
    func uniqued<ID: Hashable>(by id: (Element) -> ID) -> [Element] {
        var seen: Set<ID> = []
        return reversed().filter { seen.insert(id($0)).inserted }.reversed()
    }
}

/// A row of a listing, with the deleted mark the service may put on it — the
/// to-do lists and tasks, the digests and their groups all carry `isDeleted`.
struct Marked<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value
    let deleted: Bool

    private enum Keys: String, CodingKey { case isDeleted }

    init(from decoder: any Decoder) throws {
        value = try Value(from: decoder)
        deleted = try decoder.container(keyedBy: Keys.self).flag(.isDeleted) ?? false
    }
}
