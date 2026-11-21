// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The identifier of a digest, a digest group or a digest tag: a 64-bit
/// snowflake, which the service takes and answers as a JSON number.
public struct SNDigestID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }

    public init(from decoder: any Decoder) throws {
        rawValue = try WireInt64(from: decoder).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A digest group — what the tablet shows as a digest library.
///
/// Groups and digests are rows of one table on the server; a digest names its
/// group by the group's `uniqueIdentifier`, not by its `id`.
public struct SNDigestGroup: Sendable, Equatable, Identifiable {
    public let id: SNDigestID
    /// The name digests use to say they belong here.
    public let uniqueIdentifier: String
    public let name: String
    public let description: String?
    /// The client's fingerprint of the group, stored and never checked by the
    /// service.
    public let md5Hash: String?
    /// JSON, as a string — the service keeps it as text.
    public let metadata: String?
    public let created: Date?
    public let modified: Date?

    public init(
        id: SNDigestID,
        uniqueIdentifier: String,
        name: String,
        description: String? = nil,
        md5Hash: String? = nil,
        metadata: String? = nil,
        created: Date? = nil,
        modified: Date? = nil
    ) {
        self.id = id
        self.uniqueIdentifier = uniqueIdentifier
        self.name = name
        self.description = description
        self.md5Hash = md5Hash
        self.metadata = metadata
        self.created = created
        self.modified = modified
    }
}

/// A digest: a passage taken from a document or a note, with where it came
/// from, its tags and its comment.
public struct SNDigest: Sendable, Equatable, Identifiable {
    public let id: SNDigestID
    public let uniqueIdentifier: String?
    /// The `uniqueIdentifier` of the group it is in.
    public let groupIdentifier: String?
    /// The file it was taken from.
    public let fileID: SNFileID?
    /// The text of the passage.
    public let content: String?
    public let sourcePath: String?
    public let dataSource: String?
    /// The service's own number; which values it takes is not on record.
    public let sourceType: Int?
    /// The tags, from the comma-separated list the service keeps.
    public let tags: [String]
    /// The client's fingerprint of the digest, stored and never checked by the
    /// service.
    public let md5Hash: String?
    /// JSON, as a string — the service keeps it as text. The tablet names the
    /// digest in it, as `unique_identifier`.
    public let metadata: String?
    /// The typed comment.
    public let comment: String?
    /// The handwritten comment: its file's name on the tablet, its stored name
    /// in the cloud, and its MD5.
    public let handwritingName: String?
    public let handwritingInnerName: String?
    public let handwritingMD5: String?
    public let author: String?
    public let created: Date?
    public let modified: Date?

    public init(
        id: SNDigestID,
        uniqueIdentifier: String? = nil,
        groupIdentifier: String? = nil,
        fileID: SNFileID? = nil,
        content: String? = nil,
        sourcePath: String? = nil,
        dataSource: String? = nil,
        sourceType: Int? = nil,
        tags: [String] = [],
        md5Hash: String? = nil,
        metadata: String? = nil,
        comment: String? = nil,
        handwritingName: String? = nil,
        handwritingInnerName: String? = nil,
        handwritingMD5: String? = nil,
        author: String? = nil,
        created: Date? = nil,
        modified: Date? = nil
    ) {
        self.id = id
        self.uniqueIdentifier = uniqueIdentifier
        self.groupIdentifier = groupIdentifier
        self.fileID = fileID
        self.content = content
        self.sourcePath = sourcePath
        self.dataSource = dataSource
        self.sourceType = sourceType
        self.tags = tags
        self.md5Hash = md5Hash
        self.metadata = metadata
        self.comment = comment
        self.handwritingName = handwritingName
        self.handwritingInnerName = handwritingInnerName
        self.handwritingMD5 = handwritingMD5
        self.author = author
        self.created = created
        self.modified = modified
    }
}

/// What a sync compares: a digest's fingerprints and the time of its last
/// change, without its text.
public struct SNDigestFingerprint: Sendable, Equatable, Identifiable {
    public let id: SNDigestID
    public let md5Hash: String?
    public let handwritingMD5: String?
    public let handwritingName: String?
    public let modified: Date?
    /// `metadataMap.author`, which the service fills from the digest's author
    /// column — empty for a tablet's digest, whose author is in its metadata.
    public let author: String?

    public init(
        id: SNDigestID,
        md5Hash: String? = nil,
        handwritingMD5: String? = nil,
        handwritingName: String? = nil,
        modified: Date? = nil,
        author: String? = nil
    ) {
        self.id = id
        self.md5Hash = md5Hash
        self.handwritingMD5 = handwritingMD5
        self.handwritingName = handwritingName
        self.modified = modified
        self.author = author
    }
}

/// A tag digests can carry.
public struct SNDigestTag: Sendable, Equatable, Identifiable {
    public let id: SNDigestID
    public let name: String

    public init(id: SNDigestID, name: String) {
        self.id = id
        self.name = name
    }
}

/// What a new digest holds, or what an update changes: a field left `nil` is
/// left as it is — the service writes only the fields it is given.
public struct SNDigestDraft: Sendable, Equatable {
    public var content: String?
    /// The `uniqueIdentifier` of the group it goes in.
    public var groupIdentifier: String?
    /// The file it was taken from. Read on creation only.
    public var fileID: SNFileID?
    public var sourcePath: String?
    public var dataSource: String?
    public var sourceType: Int?
    public var tags: [String]?
    public var metadata: String?
    public var comment: String?
    public var author: String?
    /// The handwritten comment: a file `SNDigestClient.uploadHandwriting` put
    /// in the cloud. `nil` leaves the digest's as it is.
    public var handwriting: SNDigestHandwriting?
    /// The fingerprint to store. Left `nil`, it is the tablet's own sum — see
    /// `DigestFingerprint`.
    public var md5Hash: String?

    public init(
        content: String? = nil,
        groupIdentifier: String? = nil,
        fileID: SNFileID? = nil,
        sourcePath: String? = nil,
        dataSource: String? = nil,
        sourceType: Int? = nil,
        tags: [String]? = nil,
        metadata: String? = nil,
        comment: String? = nil,
        author: String? = nil,
        handwriting: SNDigestHandwriting? = nil,
        md5Hash: String? = nil
    ) {
        self.content = content
        self.groupIdentifier = groupIdentifier
        self.fileID = fileID
        self.sourcePath = sourcePath
        self.dataSource = dataSource
        self.sourceType = sourceType
        self.tags = tags
        self.metadata = metadata
        self.comment = comment
        self.author = author
        self.handwriting = handwriting
        self.md5Hash = md5Hash
    }
}

/// A handwritten comment's file, as a digest names it: the name the tablet
/// gives it, the name it is stored under in the cloud, and its MD5.
public struct SNDigestHandwriting: Sendable, Equatable {
    /// `commentHandwriteName`: the tablet names these `<32 hex>.mark`.
    public let name: String
    /// `handwriteInnerName`: the stored object, chosen by the service.
    public let innerName: String
    /// `handwriteMD5`, lowercase hex.
    public let md5: String

    public init(name: String, innerName: String, md5: String) {
        self.name = name
        self.innerName = innerName
        self.md5 = md5
    }
}

// MARK: - Decoding

/// `SummaryDO` — one row of the table groups and digests share — under the
/// service's names. `handwriteMD5` here; `handwriteMd5` in the fingerprint.
enum SummaryKeys: String, CodingKey {
    case id, fileId, name, author, uniqueIdentifier, parentUniqueIdentifier, content, sourcePath, dataSource
    case sourceType, isSummaryGroup, description, tags, md5Hash, metadata, commentStr, commentHandwriteName
    case handwriteInnerName, handwriteMD5, handwriteMd5, creationTime, lastModifiedTime, isDeleted
}

extension SNDigestGroup: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: SummaryKeys.self)
        id = try container.decode(SNDigestID.self, forKey: .id)
        uniqueIdentifier = container.text(.uniqueIdentifier) ?? ""
        name = container.text(.name) ?? ""
        description = container.text(.description)
        md5Hash = container.text(.md5Hash)
        metadata = container.text(.metadata)
        created = container.time(.creationTime)
        modified = container.time(.lastModifiedTime)
    }
}

extension SNDigest: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: SummaryKeys.self)
        id = try container.decode(SNDigestID.self, forKey: .id)
        metadata = container.text(.metadata)
        // The tablet leaves the column empty and names its digests in the
        // metadata instead.
        uniqueIdentifier = container.text(.uniqueIdentifier) ?? metadata.flatMap(SNDigest.identifier(inMetadata:))
        groupIdentifier = container.text(.parentUniqueIdentifier)
        fileID = (try? container.decodeIfPresent(SNFileID.self, forKey: .fileId)).flatMap { $0 }
        content = container.text(.content)
        sourcePath = container.text(.sourcePath)
        dataSource = container.text(.dataSource)
        sourceType = container.integer(.sourceType).map(Int.init)
        tags = SNDigest.tags(from: container.text(.tags))
        md5Hash = container.text(.md5Hash)
        comment = container.text(.commentStr)
        handwritingName = container.text(.commentHandwriteName)
        handwritingInnerName = container.text(.handwriteInnerName)
        handwritingMD5 = container.text(.handwriteMD5)
        // The tablet keeps the author in the metadata, and an update writes it
        // there: the metadata's author — an empty one too, which clears it —
        // outranks the column, which only an older digest may have filled.
        author = SNDigest.author(inMetadata: metadata) ?? container.text(.author)
        created = container.time(.creationTime)
        modified = container.time(.lastModifiedTime)
    }

    /// `unique_identifier` from a digest's metadata, where the tablet keeps it.
    static func identifier(inMetadata metadata: String) -> String? {
        value(DigestFingerprint.key, inMetadata: metadata)
    }

    /// The author the metadata names: `.some(nil)` where it names an empty one
    /// — a cleared author — and `nil` where it names none.
    static func author(inMetadata metadata: String?) -> String?? {
        guard let metadata,
              let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
              object.keys.contains(DigestFingerprint.authorKey)
        else { return nil }
        return .some((object[DigestFingerprint.authorKey] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A string field of a digest's metadata, the empty one read as none.
    static func value(_ key: String, inMetadata metadata: String) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any]
        return (object?[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func tags(from list: String?) -> [String] {
        (list ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension SNDigestFingerprint: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: SummaryKeys.self)
        id = try container.decode(SNDigestID.self, forKey: .id)
        md5Hash = container.text(.md5Hash)
        handwritingMD5 = container.text(.handwriteMd5) ?? container.text(.handwriteMD5)
        handwritingName = container.text(.commentHandwriteName)
        modified = container.time(.lastModifiedTime)
        author = Self.author(in: decoder)
    }

    private enum Outer: String, CodingKey { case metadataMap }
    private enum Inner: String, CodingKey { case author }

    /// `metadataMap.author` — the one field the fingerprint keeps of the
    /// metadata.
    private static func author(in decoder: any Decoder) -> String? {
        guard let outer = try? decoder.container(keyedBy: Outer.self),
              let map = try? outer.nestedContainer(keyedBy: Inner.self, forKey: .metadataMap)
        else { return nil }
        return (try? map.decodeIfPresent(String.self, forKey: .author)).flatMap { $0 }
    }
}

extension SNDigestTag: Decodable {
    private enum Keys: String, CodingKey { case id, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(SNDigestID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}
