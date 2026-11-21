// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The protocol client for the digest API: the passages the tablet collects
/// from documents and notes, the groups they are kept in and the tags they
/// carry.
///
/// Digest requests use the summary endpoints on the app host.
///
/// Handwritten comments use separate file upload and download endpoints.
///
/// **Deletes differ.** A digest or a group is marked deleted and stops being
/// listed; deleting a group leaves its digests where they were. A tag is
/// removed outright.
public actor SNDigestClient {
    let session: SNSession
    let channel: SNChannel
    private let now: @Sendable () -> Date

    /// How many entries one page asks for.
    static let pageSize = 100
    /// A ceiling on pages, against a server whose page count never runs out.
    static let pageLimit = 10_000

    public init(session: SNSession, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.channel = session.channel
        self.now = now
    }

    // MARK: - Groups

    /// Every digest group of the account.
    public func groups() async throws -> [SNDigestGroup] {
        try await pages(SNPath.digestGroups, query: { Query(page: $0, size: Self.pageSize) }, as: Marked<SNDigestGroup>.self)
            .uniqued(by: \.value.id)
            .filter { !$0.deleted }
            .map(\.value)
    }

    /// Make a group, and answer with its identifier.
    ///
    /// `uniqueIdentifier` is what digests will name it by; a taken one is
    /// `alreadyExists`. The fingerprint is the tablet's unless one is given —
    /// see `DigestFingerprint`.
    @discardableResult
    public func createGroup(
        named name: String,
        description: String? = nil,
        uniqueIdentifier: String = SNDigestClient.newIdentifier(),
        md5Hash: String? = nil
    ) async throws -> SNDigestID {
        let stamp = now().milliseconds
        return try await call(
            SNPath.digestGroupAdd,
            body: NewGroup(
                uniqueIdentifier: uniqueIdentifier,
                name: name,
                description: description,
                md5Hash: md5Hash ?? DigestFingerprint.group(uniqueIdentifier: uniqueIdentifier, name: name),
                creationTime: stamp,
                lastModifiedTime: stamp
            ),
            changes: true,
            as: Made.self
        ).identifier()
    }

    /// Rename a group, and give it a description — or keep the one it has,
    /// with `nil`.
    ///
    /// The new fingerprint is made of the group's `uniqueIdentifier`, which the
    /// update does not carry, so the group is looked up first unless `md5Hash`
    /// is given; one that is not listed is `notFound`.
    public func updateGroup(_ id: SNDigestID, name: String, description: String? = nil, md5Hash: String? = nil) async throws {
        var fingerprint = md5Hash
        if fingerprint == nil {
            guard let current = try await groups().first(where: { $0.id == id }) else { throw SNError.notFound(code: "E0339") }
            fingerprint = DigestFingerprint.group(uniqueIdentifier: current.uniqueIdentifier, name: name)
        }
        try await call(
            SNPath.digestGroupUpdate,
            method: "PUT",
            body: GroupChange(
                id: id,
                name: name,
                description: description,
                md5Hash: fingerprint ?? "",
                lastModifiedTime: now().milliseconds
            ),
            changes: true
        )
    }

    /// Mark a group deleted. Its digests stay, still naming it.
    public func deleteGroup(_ id: SNDigestID) async throws {
        try await call(SNPath.digestGroupDelete, method: "DELETE", body: ByID(id: id), changes: true)
    }

    // MARK: - Digests

    /// The digests in the group named `group` — its `uniqueIdentifier` — or,
    /// with `nil`, every digest of the account.
    public func digests(in group: String? = nil) async throws -> [SNDigest] {
        try await pages(
            SNPath.digests, query: { Query(page: $0, size: Self.pageSize, parentUniqueIdentifier: group) }, as: Marked<SNDigest>.self
        )
        .uniqued(by: \.value.id)
        .filter { !$0.deleted }
        .map(\.value)
    }

    /// The digests with these identifiers; the deleted and the unknown ones are
    /// left out.
    public func digests(_ ids: [SNDigestID]) async throws -> [SNDigest] {
        guard !ids.isEmpty else { return [] }
        return try await call(SNPath.digestsByID, body: ByIDs(ids: ids), changes: false, as: DigestList.self)
            .summaryDOList ?? []
    }

    /// The fingerprints of the digests in `group`, or of all of them: what a
    /// sync compares before it asks for the text.
    public func fingerprints(in group: String? = nil) async throws -> [SNDigestFingerprint] {
        try await pages(
            SNPath.digestHashes,
            query: { Query(page: $0, size: Self.pageSize, parentUniqueIdentifier: group) },
            as: SNDigestFingerprint.self
        )
        .uniqued(by: \.id)
    }

    /// The `sourceType` a tablet gave a digest typed on it, rather than taken
    /// from a document (`1`); the service's other values are not on record.
    public static let typedSourceType = 4

    /// Make a digest, and answer with its identifier.
    ///
    /// Named as the tablet names its own: `uniqueIdentifier` goes into the
    /// metadata as `unique_identifier`, and the author as `author`, merged into
    /// whatever JSON object the draft's metadata holds; the columns of those
    /// names are left empty.
    @discardableResult
    public func create(
        _ draft: SNDigestDraft,
        uniqueIdentifier: String = SNDigestClient.newIdentifier()
    ) async throws -> SNDigestID {
        try Self.check(draft)
        var draft = draft
        // What the tablet sends for a digest typed on it: a source type of 4,
        // and empty strings where it has no source, group or comment.
        draft.sourceType = draft.sourceType ?? Self.typedSourceType
        draft.sourcePath = draft.sourcePath ?? ""
        draft.groupIdentifier = draft.groupIdentifier ?? ""
        draft.comment = draft.comment ?? ""
        draft.metadata = try DigestFingerprint.metadata(draft.metadata, uniqueIdentifier: uniqueIdentifier, author: draft.author)
        let fingerprint = draft.md5Hash ?? DigestFingerprint.digest(.init(
            content: draft.content,
            group: draft.groupIdentifier,
            sourceType: draft.sourceType,
            sourcePath: draft.sourcePath,
            metadata: draft.metadata,
            comment: draft.comment,
            handwritingName: draft.handwriting?.name
        ))
        let stamp = now().milliseconds
        return try await call(
            SNPath.digestAdd,
            body: DigestBody(draft: draft, id: nil, md5Hash: fingerprint, creationTime: stamp, lastModifiedTime: stamp),
            changes: true,
            as: Made.self
        ).identifier()
    }

    /// Change the fields of a digest that `draft` names; the rest stay.
    ///
    /// A change to a field the fingerprint is made of — the content, the
    /// group, the source type and path, the metadata, the comment — gets a new fingerprint unless
    /// `md5Hash` is given; the digest is read first for the fields the draft
    /// leaves as they are, and one that is not there is `notFound`. A new
    /// author is written into the metadata, as the tablet keeps it, and so
    /// changes the fingerprint too.
    ///
    /// Two writes to one digest from this session are not run side by side: a
    /// fingerprint worked out from the digest as one of them read it would not
    /// be the fingerprint of what both of them leave. The second is refused
    /// with `rejected(code: "SNCloud.busy")`. Another device writing at the
    /// same moment cannot be kept out — the service has no conditional write.
    public func update(_ id: SNDigestID, with draft: SNDigestDraft) async throws {
        try Self.check(draft)
        try await exclusively(id) { try await self.write(id, with: draft) }
    }

    private func write(_ id: SNDigestID, with draft: SNDigestDraft) async throws {
        var draft = draft
        var fingerprint = draft.md5Hash
        let hashed = draft.content != nil || draft.groupIdentifier != nil || draft.sourceType != nil
            || draft.sourcePath != nil || draft.metadata != nil || draft.comment != nil || draft.author != nil
            || draft.handwriting != nil
        if hashed, fingerprint == nil || draft.author != nil {
            guard let current = try await digests([id]).first else { throw SNError.notFound(code: "E0340") }
            if let author = draft.author {
                draft.metadata = try DigestFingerprint.metadata(draft.metadata ?? current.metadata, uniqueIdentifier: nil, author: author)
            }
            if fingerprint == nil {
                fingerprint = DigestFingerprint.digest(.init(
                    content: draft.content ?? current.content,
                    group: draft.groupIdentifier ?? current.groupIdentifier,
                    sourceType: draft.sourceType ?? current.sourceType,
                    sourcePath: draft.sourcePath ?? current.sourcePath,
                    metadata: draft.metadata ?? current.metadata,
                    comment: draft.comment ?? current.comment,
                    handwritingName: draft.handwriting?.name ?? current.handwritingName
                ))
            }
        }
        try await call(
            SNPath.digestUpdate,
            method: "PUT",
            body: DigestBody(draft: draft, id: id, md5Hash: fingerprint, creationTime: nil, lastModifiedTime: now().milliseconds),
            changes: true
        )
    }

    /// Mark a digest deleted. Not while a write to it from this session runs.
    public func delete(_ id: SNDigestID) async throws {
        try await exclusively(id) {
            try await self.call(SNPath.digestDelete, method: "DELETE", body: ByID(id: id), changes: true)
        }
    }

    /// `body`, with the digest claimed on the session for its length.
    private func exclusively(_ id: SNDigestID, _ body: @Sendable () async throws -> Void) async throws {
        guard await session.claimDigestWrite(id.rawValue) else {
            throw SNError.rejected(code: Self.busy, message: "another write to digest \(id) is running on this session")
        }
        do {
            try await body()
            await session.releaseDigestWrite(id.rawValue)
        } catch {
            await session.releaseDigestWrite(id.rawValue)
            throw error
        }
    }

    /// The code of the refusal a second write to one digest meets.
    public static let busy = "SNCloud.busy"

    // MARK: - Handwritten comments

    /// Put a handwritten comment's file in the cloud, and answer with what a
    /// digest names it by — to be set as its `SNDigestDraft.handwriting`.
    ///
    /// `name` is the name the tablet keeps it under, `<32 hex>.mark` unless
    /// given. The service answers the apply as it answers a file's — an S3
    /// object signed for one PUT on the official cloud, a form on a private one
    /// — and the bytes go the same way, with the stored name the service chose.
    public func uploadHandwriting(contentsOf file: URL, named name: String? = nil) async throws -> SNDigestHandwriting {
        let name = name ?? "\(Self.newIdentifier()).mark"
        let original = try Original.measure(file, name: name)
        // One login from the apply to the last byte, as for a file.
        let login = await session.loginGeneration()
        let slot = try await channel.call(
            SNPath.digestHandwritingApply,
            on: .app,
            body: HandwritingApply(fileName: name, equipmentNo: try await session.identity().equipmentNo),
            by: session,
            channel: true,
            changes: false,
            generation: login,
            as: UploadSlot.self
        )
        let signer = channel.s3Signer(session: session, fileServer: slot.fileServer, generation: login)
        let server = FormServer(host: channel.endpoints.appHost, token: try await session.accessToken(forGeneration: login))
        let stored = try await Transfers(channel: channel).send(original, to: slot, signer: signer, server: server, onProgress: { _, _ in })
        return SNDigestHandwriting(name: name, innerName: slot.innerName ?? stored, md5: original.md5)
    }

    /// The handwritten comment's file of `digest`, into a temporary file the
    /// caller then owns, checked against its MD5 — or `nil` for a digest that
    /// has none.
    public func handwriting(of digest: SNDigest, onProgress: @escaping TransferProgress = { _, _ in }) async throws -> URL? {
        guard digest.handwritingInnerName != nil else { return nil }
        let link = try await call(SNPath.digestHandwriting, body: ByID(id: digest.id), changes: false, as: HandwritingLink.self)
        guard let url = link.url.flatMap(URL.init(string:)) else {
            throw SNError.malformedResponse("download/summary named no link")
        }
        return try await Transfers(channel: channel).fetch(
            url.servedFrom(channel.endpoints.appHost),
            limit: Transfers.downloadLimit,
            md5: digest.handwritingMD5,
            onProgress: onProgress
        )
    }

    // MARK: - Tags

    /// Every tag of the account.
    public func tags() async throws -> [SNDigestTag] {
        try await call(SNPath.digestTags, method: "GET", body: NoBody(), changes: false, as: TagList.self).summaryTagDOList ?? []
    }

    /// Make a tag. A name already taken is `alreadyExists`.
    @discardableResult
    public func createTag(named name: String) async throws -> SNDigestID {
        try await call(SNPath.digestTagAdd, body: TagName(name: name), changes: true, as: Made.self).identifier()
    }

    /// Rename a tag. A name already taken is `alreadyExists`; an unknown tag
    /// is `notFound`.
    public func renameTag(_ id: SNDigestID, to name: String) async throws {
        try await call(SNPath.digestTagUpdate, method: "PUT", body: TagChange(id: id, name: name), changes: true)
    }

    /// Delete a tag, for good. The digests that carry it keep its name.
    public func deleteTag(_ id: SNDigestID) async throws {
        try await call(SNPath.digestTagDelete, method: "DELETE", body: ByID(id: id), changes: true)
    }

    // MARK: - Inside

    /// A new `uniqueIdentifier` in the tablet's form: 32 lowercase hex digits.
    public static func newIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// A tag with a comma in it would come back as two: the service keeps a
    /// digest's tags as one comma-separated string.
    static func check(_ draft: SNDigestDraft) throws {
        if let tag = draft.tags?.first(where: { $0.contains(",") }) {
            throw SNError.malformedResponse("a digest tag cannot contain a comma: \(tag)")
        }
    }

    /// Every page of a paged query, from the first, until the service's page
    /// count is reached or a page comes back empty.
    private func pages<Item: Decodable & Sendable>(
        _ path: String,
        query: (_ page: Int) -> Query,
        as item: Item.Type
    ) async throws -> [Item] {
        let generation = await session.loginGeneration()
        var items: [Item] = []
        for page in 1...Self.pageLimit {
            let answer = try await call(path, body: query(page), changes: false, generation: generation, as: Page<Item>.self)
            let rows = answer.rows
            items += rows
            // Without a page count, a short page is the last one.
            let last = answer.totalPages.map { Int64(page) >= $0.value } ?? (rows.count < Self.pageSize)
            if rows.isEmpty || last { return items }
        }
        throw SNError.malformedResponse("the digest listing ran past \(Self.pageLimit) pages")
    }

    private func call<Payload: Decodable & Sendable>(
        _ path: String,
        method: String = "POST",
        body: some Encodable & Sendable,
        changes: Bool,
        generation: Int? = nil,
        as payload: Payload.Type
    ) async throws -> Payload {
        // With `channel`, so that the change feed leaves this installation's
        // own changes out of what it announces to it.
        try await channel.call(
            path, on: .app, method: method, body: body, by: session, channel: true, changes: changes,
            generation: generation, as: Payload.self
        )
    }

    private func call(_ path: String, method: String = "POST", body: some Encodable & Sendable, changes: Bool) async throws {
        _ = try await call(path, method: method, body: body, changes: changes, as: SNChannel.Nothing.self)
    }
}

// MARK: - Wire shapes

/// A paged query. `page` and `size` are always sent: the service unboxes both
/// and fails with a bare `500` on a missing one.
private struct Query: Encodable {
    let page: Int
    let size: Int
    var parentUniqueIdentifier: String?
}

/// A page of any of the three paged answers; the rows sit under a name of
/// their own in each.
private struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    let totalPages: WireInt64?
    let rows: [Item]

    private enum Keys: String, CodingKey { case totalPages, summaryDOList, summaryInfoVOList }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        totalPages = try? container.decodeIfPresent(WireInt64.self, forKey: .totalPages)
        rows = try container.decodeIfPresent([Item].self, forKey: .summaryDOList)
            ?? container.decodeIfPresent([Item].self, forKey: .summaryInfoVOList)
            ?? []
    }
}

private struct DigestList: Decodable {
    let summaryDOList: [SNDigest]?
}

private struct HandwritingApply: Encodable {
    let fileName: String
    let equipmentNo: String
}

private struct HandwritingLink: Decodable {
    let url: String?
}

private struct TagList: Decodable {
    let summaryTagDOList: [SNDigestTag]?
}

/// What every "add" answers: the new row's identifier.
private struct Made: Decodable {
    let id: SNDigestID?

    func identifier() throws -> SNDigestID {
        guard let id else { throw SNError.malformedResponse("the digest API named no new identifier") }
        return id
    }
}

private struct ByID: Encodable {
    let id: SNDigestID
}

private struct ByIDs: Encodable {
    let ids: [SNDigestID]
}

private struct TagName: Encodable {
    let name: String
}

private struct TagChange: Encodable {
    let id: SNDigestID
    let name: String
}

private struct NewGroup: Encodable {
    let uniqueIdentifier: String
    let name: String
    let description: String?
    let md5Hash: String
    let creationTime: Int64
    let lastModifiedTime: Int64
}

private struct GroupChange: Encodable {
    let id: SNDigestID
    let name: String
    let description: String?
    let md5Hash: String
    let lastModifiedTime: Int64
}

/// A digest's fields under the service's names, those the draft leaves `nil`
/// left out — which is what makes an update touch only the rest.
private struct DigestBody: Encodable {
    let draft: SNDigestDraft
    let id: SNDigestID?
    let md5Hash: String?
    let creationTime: Int64?
    let lastModifiedTime: Int64

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: SummaryKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        if id == nil { try container.encodeIfPresent(draft.fileID?.rawValue, forKey: .fileId) }
        try container.encodeIfPresent(draft.groupIdentifier, forKey: .parentUniqueIdentifier)
        try container.encodeIfPresent(draft.content, forKey: .content)
        try container.encodeIfPresent(draft.sourcePath, forKey: .sourcePath)
        try container.encodeIfPresent(draft.dataSource, forKey: .dataSource)
        try container.encodeIfPresent(draft.sourceType, forKey: .sourceType)
        try container.encodeIfPresent(draft.tags?.joined(separator: ","), forKey: .tags)
        try container.encodeIfPresent(draft.metadata, forKey: .metadata)
        try container.encodeIfPresent(draft.comment, forKey: .commentStr)
        if let handwriting = draft.handwriting {
            try container.encode(handwriting.name, forKey: .commentHandwriteName)
            try container.encode(handwriting.innerName, forKey: .handwriteInnerName)
            try container.encode(handwriting.md5, forKey: .handwriteMD5)
        } else if id == nil {
            // A new digest without one, which the tablet sends as "".
            try container.encode("", forKey: .commentHandwriteName)
        }
        // The author goes in the metadata, as the tablet keeps it.
        try container.encodeIfPresent(md5Hash, forKey: .md5Hash)
        try container.encodeIfPresent(creationTime, forKey: .creationTime)
        try container.encode(lastModifiedTime, forKey: .lastModifiedTime)
    }
}

/// Client-computed fingerprints for groups and digests.
///
/// - a group: `md5(uniqueIdentifier + name)` — the tablet gives a group no
///   description, so none is summed;
/// - a digest: `md5(content + parentUniqueIdentifier + sourceType + sourcePath
///   + metadata + commentStr + commentHandwriteName)`, the metadata as the
///   JSON text stored.
///
/// Missing fields contribute an empty string. The service stores the supplied hash.
enum DigestFingerprint {
    static func group(uniqueIdentifier: String, name: String) -> String {
        Digests.md5(Data((uniqueIdentifier + name).utf8))
    }

    /// The fields a digest's fingerprint is summed from, in the order summed.
    struct Fields {
        var content: String?
        var group: String?
        var sourceType: Int?
        var sourcePath: String?
        var metadata: String?
        var comment: String?
        var handwritingName: String?
    }

    static func digest(_ fields: Fields) -> String {
        let parts = [
            fields.content, fields.group, fields.sourceType.map(String.init), fields.sourcePath, fields.metadata,
            fields.comment, fields.handwritingName,
        ]
        return Digests.md5(Data(parts.map { $0 ?? "" }.joined().utf8))
    }

    /// `metadata` with `unique_identifier` in it — added to the JSON object it
    /// holds, unless that object names one already — and with `author` set
    /// when one is given. Metadata that is not a JSON object is refused: there
    /// is nowhere in it to put either.
    static func metadata(_ metadata: String?, uniqueIdentifier: String?, author: String?) throws -> String {
        var object: [String: Any] = [:]
        if let metadata, !metadata.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any] else {
                throw SNError.malformedResponse("a digest's metadata must be a JSON object")
            }
            object = parsed
        }
        if let uniqueIdentifier, object[key] == nil { object[key] = uniqueIdentifier }
        if let author { object[authorKey] = author }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static let key = "unique_identifier"
    static let authorKey = "author"
}
