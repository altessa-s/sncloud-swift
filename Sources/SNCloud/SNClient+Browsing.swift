// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The tree: what is in a folder, where an entry is, and the changes that
/// rearrange it.
extension SNClient {
    /// How many entries one page asks for. The service pages every listing, and
    /// the web page asks for a hundred at most; a folder of thousands is still
    /// read whole, a hundred at a time.
    static let pageSize = 100

    /// Where a walk over pages gives up whatever the server keeps saying: past
    /// a million entries a listing is not a folder any more, it is a loop.
    static let pageCeiling = 10_000

    /// Everything in `folder`, every page of it.
    public func list(
        _ folder: SNFileID = .root,
        order: SNSortOrder = .name,
        ascending: Bool = true
    ) async throws -> [SNEntry] {
        try await pages { page, generation in
            let answer = try await authorized(
                SNPath.list,
                body: ListRequest(
                    directoryId: folder,
                    order: order.rawValue,
                    sequence: ascending ? "asc" : "desc",
                    pageNo: page,
                    pageSize: Self.pageSize
                ),
                changes: false,
                generation: generation,
                as: ListAnswer.self
            )
            return (answer.userFileVOList ?? [], answer.total?.value, answer.pages?.value)
        }
    }

    /// Entries whose name contains `name`, anywhere in the tree.
    public func search(
        _ name: String,
        order: SNSortOrder = .name,
        ascending: Bool = true
    ) async throws -> [SNEntry] {
        try await pages { page, generation in
            let answer = try await authorized(
                SNPath.search,
                body: SearchRequest(
                    fileName: name,
                    order: order.rawValue,
                    sequence: ascending ? "asc" : "desc",
                    pageNo: page,
                    pageSize: Self.pageSize
                ),
                changes: false,
                generation: generation,
                as: SearchAnswer.self
            )
            return (answer.userFileSearchVOList ?? [], answer.total?.value, nil)
        }
    }

    /// The folders directly in `folder`, and nothing else — what the official
    /// app shows when it asks where to move something.
    ///
    /// `excluding` leaves those folders out: the ones being moved, which
    /// cannot go into themselves. At the top the service answers as the web
    /// page shows it — `Note` and `Document` rather than the `NOTE` and
    /// `DOCUMENT` they live in, and `MyStyle` beside them.
    public func folders(in folder: SNFileID = .root, excluding: [SNFileID] = []) async throws -> [SNFolder] {
        // The list may not be empty, and the folder itself is never among its
        // own children: it stands in when nothing is to be left out.
        let answer = try await authorized(
            SNPath.folders,
            body: FoldersRequest(directoryId: folder, idList: excluding.isEmpty ? [folder] : excluding),
            changes: false,
            as: FoldersAnswer.self
        )
        return (answer.folderVOList ?? []).uniqued(by: \.id)
    }

    /// The entry called `name` directly in `folder`, if there is one.
    public func entry(named name: String, in folder: SNFileID = .root) async throws -> SNEntry? {
        try await list(folder).first { $0.name == name }
    }

    /// Walk pages until the server has nothing more to say.
    ///
    /// Three ways to know a listing is over, because the answers carry
    /// different subsets of the counts: an empty page, a total reached, or the
    /// last of the pages the answer said there were.
    func pages<Item>(
        _ fetch: (Int, Int) async throws -> (entries: [Item], total: Int64?, pages: Int64?)
    ) async throws -> [Item] {
        let generation = await session.loginGeneration()
        var all: [Item] = []
        for page in 1...Self.pageCeiling {
            let (entries, total, pages) = try await fetch(page, generation)
            all += entries
            if entries.isEmpty { return all }
            if let total, Int64(all.count) >= total { return all }
            if let pages, Int64(page) >= pages { return all }
            if entries.count < Self.pageSize, total == nil, pages == nil { return all }
        }
        throw SNError.malformedResponse("the listing ran past \(Self.pageCeiling) pages")
    }

    /// Make a folder called `name` in `parent`, and answer with it.
    ///
    /// The service answers a new folder with `{"success": true}` and nothing
    /// else — no identifier — so the folder is found again by name in a fresh
    /// listing of its parent. A name already taken is `alreadyExists`.
    @discardableResult
    public func createFolder(named name: String, in parent: SNFileID = .root) async throws -> SNEntry {
        try await authorized(
            SNPath.createFolder,
            body: FolderRequest(fileName: name, directoryId: parent),
            changes: true
        )
        guard let folder = try await list(parent).first(where: { $0.isFolder && $0.name == name }) else {
            throw SNError.malformedResponse("the new folder \(name) is not in its parent's listing")
        }
        return folder
    }

    /// Move entries to the recycle bin. `parent` is the folder they are in:
    /// the service asks for it, and every entry has to be in that one folder.
    public func delete(_ ids: [SNFileID], from parent: SNFileID) async throws {
        guard !ids.isEmpty else { return }
        try await authorized(SNPath.delete, body: DeleteRequest(idList: ids, directoryId: parent), changes: true)
    }

    /// Move entries out of `parent` into `destination`.
    public func move(_ ids: [SNFileID], from parent: SNFileID, to destination: SNFileID) async throws {
        guard !ids.isEmpty else { return }
        try await authorized(
            SNPath.move,
            body: TransferRequest(idList: ids, directoryId: parent, goDirectoryId: destination),
            changes: true
        )
    }

    /// Copy entries out of `parent` into `destination`. The service copies at
    /// most a thousand at once.
    public func copy(_ ids: [SNFileID], from parent: SNFileID, to destination: SNFileID) async throws {
        guard !ids.isEmpty else { return }
        try await authorized(
            SNPath.copy,
            body: TransferRequest(idList: ids, directoryId: parent, goDirectoryId: destination),
            changes: true
        )
    }

    /// Give an entry a new name, in the folder it is in.
    public func rename(_ id: SNFileID, to name: String) async throws {
        try await authorized(SNPath.rename, body: RenameRequest(id: id, newName: name), changes: true)
    }

    /// How much of the account's storage is in use.
    public func capacity() async throws -> SNCapacity {
        try await authorized(SNPath.capacity, body: EmptyBody(), changes: false, as: SNCapacity.self)
    }

    /// Who is logged in, as the service has them.
    public func user() async throws -> SNUser {
        try await authorized(SNPath.user, body: EmptyBody(), changes: false, as: SNUser.self)
    }

    /// Where an entry is: the folders from the root down to it, by name and by
    /// identifier.
    public func location(of id: SNFileID) async throws -> SNLocation {
        let answer = try await authorized(SNPath.path, body: IDRequest(id: id), changes: false, as: PathAnswer.self)
        let names = (answer.path ?? "").split(separator: "/").map(String.init)
        let ids = (answer.idPath ?? "").split(separator: "/").compactMap { Int64($0) }.map(SNFileID.init(rawValue:))
        return SNLocation(names: names, ids: ids)
    }
}

// MARK: - Wire shapes

private struct ListRequest: Encodable {
    let directoryId: SNFileID
    let order: String
    let sequence: String
    let pageNo: Int
    let pageSize: Int
}

private struct SearchRequest: Encodable {
    let fileName: String
    let order: String
    let sequence: String
    let pageNo: Int
    let pageSize: Int
}

private struct ListAnswer: Decodable {
    let total: WireInt64?
    let pages: WireInt64?
    let userFileVOList: [SNEntry]?
}

private struct SearchAnswer: Decodable {
    let total: WireInt64?
    let userFileSearchVOList: [SNEntry]?
}

private struct FolderRequest: Encodable {
    let fileName: String
    let directoryId: SNFileID
}

private struct DeleteRequest: Encodable {
    let idList: [SNFileID]
    let directoryId: SNFileID
}

private struct TransferRequest: Encodable {
    let idList: [SNFileID]
    let directoryId: SNFileID
    let goDirectoryId: SNFileID
}

private struct RenameRequest: Encodable {
    let id: SNFileID
    let newName: String
}

private struct FoldersRequest: Encodable {
    let directoryId: SNFileID
    let idList: [SNFileID]
}

private struct FoldersAnswer: Decodable {
    let folderVOList: [SNFolder]?
}

struct IDRequest: Encodable {
    let id: SNFileID
}

private struct PathAnswer: Decodable {
    let path: String?
    let idPath: String?
}
