// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A file or folder's identifier: a 64-bit snowflake, and `0` for the root.
///
/// A type of its own rather than a bare `Int64`, because a file's size and a
/// folder's identifier are both 64-bit integers in the same answer, and the
/// compiler is the cheapest place to keep them apart.
///
/// Sent as a JSON **string**, which is what the service's own web page sends:
/// the server accepts both, but eighteen digits do not survive anything on the
/// way that reads JSON numbers as doubles.
public struct SNFileID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// The top of the tree: `Note`, `Document`, `Inbox`, `Export`,
    /// `Screenshot` and `MyStyle` live here.
    public static let root = SNFileID(rawValue: 0)

    public var description: String { String(rawValue) }

    public init(from decoder: any Decoder) throws {
        rawValue = try WireInt64(from: decoder).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(rawValue))
    }
}

/// One file or folder, as a listing or a search names it.
public struct SNEntry: Sendable, Equatable, Identifiable {
    public let id: SNFileID
    /// The folder it is in.
    public let parentID: SNFileID
    public let name: String
    public let isFolder: Bool
    /// Bytes. `nil` for a folder, and wherever the service did not say.
    public let size: Int64?
    /// The content's MD5, lowercase hex: what tells a changed file from an
    /// unchanged one without downloading it.
    public let md5: String?
    public let created: Date?
    public let modified: Date?
    /// The containing folder's name — a search answers with it, a listing does
    /// not.
    public let parentName: String?

    public init(
        id: SNFileID,
        parentID: SNFileID,
        name: String,
        isFolder: Bool,
        size: Int64? = nil,
        md5: String? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        parentName: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.md5 = md5
        self.created = created
        self.modified = modified
        self.parentName = parentName
    }
}

extension SNEntry: Decodable {
    private enum Keys: String, CodingKey {
        case id, directoryId, fileName, isFolder, size, md5, createTime, updateTime, directoryName
    }

    /// `UserFileVO` and `UserFileSearchVO` alike: the two share every field but
    /// `directoryName` and `createTime`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(SNFileID.self, forKey: .id)
        parentID = try container.decodeIfPresent(SNFileID.self, forKey: .directoryId) ?? .root
        name = try container.decode(String.self, forKey: .fileName)
        isFolder = try container.decodeIfPresent(WireFlag.self, forKey: .isFolder)?.value ?? false
        size = try? container.decodeIfPresent(WireInt64.self, forKey: .size)?.value
        let md5 = try container.decodeIfPresent(String.self, forKey: .md5)?.lowercased()
        self.md5 = md5?.isEmpty == true ? nil : md5
        created = container.milliseconds(.createTime)
        modified = container.milliseconds(.updateTime)
        parentName = try container.decodeIfPresent(String.self, forKey: .directoryName)
    }
}

/// A folder, as the folder-only listing names it.
public struct SNFolder: Sendable, Equatable, Identifiable {
    public let id: SNFileID
    /// The folder it is in.
    public let parentID: SNFileID
    public let name: String
    /// Whether there are folders in it — the service's `empty` is about
    /// folders only, not files.
    public let hasSubfolders: Bool

    public init(id: SNFileID, parentID: SNFileID, name: String, hasSubfolders: Bool) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.hasSubfolders = hasSubfolders
    }
}

extension SNFolder: Decodable {
    private enum Keys: String, CodingKey { case id, directoryId, fileName, empty }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(SNFileID.self, forKey: .id)
        parentID = (try? container.decodeIfPresent(SNFileID.self, forKey: .directoryId)) ?? .root
        name = container.text(.fileName) ?? ""
        hasSubfolders = !(container.flag(.empty) ?? true)
    }
}

/// How a listing is ordered. The service refuses a listing that names no order
/// at all — "Sorting condition cannot be empty" — so there is no default on the
/// wire, only this one.
///
/// Frozen, for the reason given on `SNError`.
@frozen
public enum SNSortOrder: String, Sendable, CaseIterable {
    case name = "filename"
    case time = "time"
    case size = "size"
}

// Equality spelled out rather than synthesised; see `SNError`.
extension SNSortOrder {
    public static func == (lhs: SNSortOrder, rhs: SNSortOrder) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

/// The account's storage.
public struct SNCapacity: Sendable, Equatable, Decodable {
    /// Bytes in use.
    public let used: Int64
    /// Bytes the plan allows.
    public let total: Int64

    public init(used: Int64, total: Int64) {
        self.used = used
        self.total = total
    }

    private enum Keys: String, CodingKey {
        case usedCapacity, totalCapacity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        used = try container.decode(WireInt64.self, forKey: .usedCapacity).value
        total = try container.decode(WireInt64.self, forKey: .totalCapacity).value
    }
}

/// Where an entry is, by name and by identifier, from the root down.
public struct SNLocation: Sendable, Equatable {
    /// `["Note", "Meetings"]`, from `"Note/Meetings/"`.
    public let names: [String]
    public let ids: [SNFileID]

    public init(names: [String], ids: [SNFileID]) {
        self.names = names
        self.ids = ids
    }
}

/// Who is logged in.
public struct SNUser: Sendable, Equatable {
    public let id: Int64?
    public let name: String?
    public let email: String?
    public let phone: String?
    public let countryCode: String?
    public let avatarURL: URL?

    public init(
        id: Int64?,
        name: String?,
        email: String?,
        phone: String?,
        countryCode: String?,
        avatarURL: URL?
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
        self.countryCode = countryCode
        self.avatarURL = avatarURL
    }
}

extension SNUser: Decodable {
    private enum Keys: String, CodingKey {
        case userId, userName, email, telephone, countryCode, avatarsUrl
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try? container.decodeIfPresent(WireInt64.self, forKey: .userId)?.value
        name = try container.decodeIfPresent(String.self, forKey: .userName).nonEmpty
        email = try container.decodeIfPresent(String.self, forKey: .email).nonEmpty
        phone = try container.decodeIfPresent(String.self, forKey: .telephone).nonEmpty
        countryCode = (try? container.decodeIfPresent(WireEcho.self, forKey: .countryCode)).flatMap {
            switch $0 {
            case .number(let number): String(number)
            case .text(let text): text.isEmpty ? nil : text
            }
        }
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarsUrl).nonEmpty.flatMap(URL.init(string:))
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
