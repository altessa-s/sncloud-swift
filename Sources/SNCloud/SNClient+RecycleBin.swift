// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// One entry in the recycle bin: what `delete` put there.
public struct SNRecycledEntry: Sendable, Equatable, Identifiable {
    /// The identifier it had in the tree, and will have again when restored.
    public let id: SNFileID
    public let name: String
    public let isFolder: Bool
    /// Bytes; `nil` for a folder and where the service did not say.
    public let size: Int64?
    /// When it was put in the bin.
    public let deleted: Date?

    public init(id: SNFileID, name: String, isFolder: Bool, size: Int64? = nil, deleted: Date? = nil) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.deleted = deleted
    }
}

extension SNRecycledEntry: Decodable {
    private enum Keys: String, CodingKey { case fileId, fileName, isFolder, size, updateTime }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(SNFileID.self, forKey: .fileId)
        name = container.text(.fileName) ?? ""
        isFolder = container.flag(.isFolder) ?? false
        let bytes = container.integer(.size)
        size = isFolder ? nil : bytes
        deleted = container.instant(.updateTime)
    }
}

/// The recycle bin: what is in it, getting things back, and getting rid of
/// them for good.
///
/// List, restore, delete or empty the bin. Entries keep their original file identifiers.
extension SNClient {
    /// Everything in the recycle bin, every page of it.
    public func recycleBin(order: SNSortOrder = .time, ascending: Bool = false) async throws -> [SNRecycledEntry] {
        try await pages { page, generation in
            let answer = try await authorized(
                SNPath.recycleList,
                body: RecycleListRequest(
                    order: order.rawValue, sequence: ascending ? "asc" : "desc", pageNo: page, pageSize: Self.pageSize
                ),
                changes: false,
                generation: generation,
                as: RecycleAnswer.self
            )
            return (answer.recycleFileVOList ?? [], answer.total?.value, nil)
        }
        .uniqued(by: \.id)
    }

    /// Put entries back where they were. A folder they were in that is gone
    /// too comes back with them. An entry no longer in the bin is `notFound`
    /// (`E0311`) — and then none of them is restored; a sync in progress is
    /// `syncLocked`.
    public func restore(_ ids: [SNFileID]) async throws {
        guard !ids.isEmpty else { return }
        try await authorized(SNPath.recycleRestore, body: RecycleRequest(ids), changes: true)
    }

    /// Delete entries from the recycle bin for good. An entry no longer in the
    /// bin is `notFound` (`E0311`), and then none of them is deleted.
    public func deleteForever(_ ids: [SNFileID]) async throws {
        guard !ids.isEmpty else { return }
        try await authorized(SNPath.recycleDelete, body: RecycleRequest(ids), changes: true)
        Log.supernote.info("deleted \(ids.count, .public) entries from the recycle bin")
    }

    /// Delete everything in the recycle bin, for good.
    public func emptyRecycleBin() async throws {
        try await authorized(SNPath.recycleClear, body: EmptyBody(), changes: true)
        Log.supernote.info("emptied the recycle bin")
    }
}

// MARK: - Wire shapes

private struct RecycleListRequest: Encodable {
    let order: String
    let sequence: String
    let pageNo: Int
    let pageSize: Int
}

private struct RecycleAnswer: Decodable {
    let total: WireInt64?
    let recycleFileVOList: [SNRecycledEntry]?
}

/// Each identifier once: the service counts the entries it found against the
/// list it was sent, and a repeated one reads as an entry gone from the bin.
private struct RecycleRequest: Encodable {
    let idList: [SNFileID]

    init(_ ids: [SNFileID]) {
        idList = ids.uniqued(by: \.self)
    }
}
