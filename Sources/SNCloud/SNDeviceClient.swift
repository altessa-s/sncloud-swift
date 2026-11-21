// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// The protocol client for the device API: the tree by path, the way the
/// tablets sync it.
///
/// What it has that the web API does not: the whole tree in one answer
/// (`list(recursive: true)`), a content hash on every entry, lookups by path,
/// an upload that answers with the new file's identifier, and downloads by
/// byte range. What it costs: a device serial on every call, and paths spelled
/// the way the server stores them — `NOTE/Note/…`, not the web page's `Note/…`.
///
/// Requests use the app host and identify the installation in the body,
/// equipment header and channel using the session's `SNDeviceIdentity`.
/// No device login is made and no tablet's session is
/// touched: an account can hold several of these at once.
///
/// **The sync lock is opt-in.** A tablet brackets its sync with
/// `synchronous/start` and `synchronous/end`, and the start takes a lock on the
/// account that turns another device's start away with `E0078`. The calls in
/// between do not ask for it — one reference client makes them bare — so this
/// client takes the lock only inside `withSyncLock`, for a host that wants its
/// own changes not to interleave with a tablet's.
public actor SNDeviceClient {
    let session: SNSession
    let channel: SNChannel

    public init(session: SNSession) {
        self.session = session
        self.channel = session.channel
    }

    /// What this client calls itself in the body of every call:
    /// `<PLATFORM>-<uuid>`, the session's `SNDeviceIdentity`.
    ///
    /// The official app sends exactly this — `MACOS-<uuid>` from a Mac — and
    /// the same device, spelled with an underscore, in the `equipmentNo` header.
    /// It is also whose the sync lock is: a lock is released only under the
    /// name it was taken under.
    public var equipmentNo: String {
        get async throws { try await session.identity().equipmentNo }
    }

    // MARK: - Reading

    /// What is in the folder at `path` — `/` for the top — and, with
    /// `recursive`, everything under it, flat.
    ///
    /// UltraBridge reads only an identifier from this call and
    /// lists the root whatever the path says; against it, use `list(folder:)`.
    public func list(path: String = "/", recursive: Bool = false) async throws -> [SNDeviceEntry] {
        let entries = try await call(
            SNPath.deviceList,
            body: ListByPath(equipmentNo: try await equipmentNo, path: DevicePath.absolute(path), recursive: recursive),
            changes: false,
            as: Listing.self
        ).entries ?? []
        // One folder's listing names that folder for each entry; reading it so
        // is certain where `SNDeviceEntry.place` has to guess.
        return recursive ? entries : entries.map { $0.listed(in: path) }
    }

    /// The same, for the folder with identifier `folder`.
    public func list(folder: SNFileID, recursive: Bool = false) async throws -> [SNDeviceEntry] {
        try await call(
            SNPath.deviceListByID,
            body: ListByID(equipmentNo: try await equipmentNo, id: folder.rawValue, recursive: recursive),
            changes: false,
            as: Listing.self
        ).entries ?? []
    }

    /// The entry with identifier `id`, or `nil` when there is none — the server
    /// answers a missing one with `entriesVO: null`, not with an error.
    public func entry(_ id: SNFileID) async throws -> SNDeviceEntry? {
        try await call(
            SNPath.deviceQuery, body: ByID(equipmentNo: try await equipmentNo, id: id), changes: false, as: Found.self
        ).entriesVO
    }

    /// The entry at `path`, or `nil` when there is none.
    public func entry(atPath path: String) async throws -> SNDeviceEntry? {
        try await call(
            SNPath.deviceQueryByPath,
            body: ByPath(equipmentNo: try await equipmentNo, path: DevicePath.absolute(path)),
            changes: false,
            as: Found.self
        ).entriesVO
    }

    /// How much of the account's storage is in use, and how much the plan
    /// allocates.
    public func spaceUsage() async throws -> SNSpaceUsage {
        try await call(SNPath.deviceSpace, body: Device(equipmentNo: try await equipmentNo), changes: false, as: SNSpaceUsage.self)
    }

    // MARK: - Changing

    /// Make the folder at `path`, and answer with it — identifier included,
    /// which is what the tablets parent their next upload to.
    ///
    /// A name already taken is `alreadyExists`, unless `autorename` asks the
    /// server to pick another. Every tablet sends `autorename: false`.
    @discardableResult
    public func createFolder(atPath path: String, autorename: Bool = false) async throws -> SNDeviceEntry {
        let answer = try await call(
            SNPath.deviceCreateFolder,
            body: CreateFolder(equipmentNo: try await equipmentNo, path: DevicePath.absolute(path), autorename: autorename),
            changes: true,
            as: Created.self
        )
        guard let folder = answer.metadata else { throw SNError.malformedResponse("create_folder_v2 named no folder") }
        return folder
    }

    /// Delete a file or a folder — **for good**: unlike the web API's delete,
    /// this one does not go through the recycle bin (Ratta's server removes the
    /// row outright, and a run against it confirmed nothing reached the bin).
    ///
    /// The tablets never send this for a folder: they delete what is in one, a
    /// file at a time, and leave the empty folder to the server. What the
    /// official cloud does with a folder's identifier here is not on record.
    public func delete(_ id: SNFileID) async throws {
        try await call(SNPath.deviceDelete, body: ByID(equipmentNo: try await equipmentNo, id: id), changes: true)
    }

    /// Move an entry to `path` — the **whole** destination, new name included,
    /// not the folder it goes into. A rename is a move within one folder.
    ///
    /// Spelled out because the server's own description says "target parent
    /// directory", and a re-implementation that believed it nested files into
    /// folders named after them.
    @discardableResult
    public func move(_ id: SNFileID, toPath path: String, autorename: Bool = false) async throws -> SNDeviceEntry? {
        try await call(
            SNPath.deviceMove,
            body: Relocate(equipmentNo: try await equipmentNo, id: id, toPath: DevicePath.absolute(path), autorename: autorename),
            changes: true,
            as: Found.self
        ).entriesVO
    }

    /// Copy an entry to `path`, the whole destination as for `move`.
    @discardableResult
    public func copy(_ id: SNFileID, toPath path: String, autorename: Bool = false) async throws -> SNDeviceEntry? {
        try await call(
            SNPath.deviceCopy,
            body: Relocate(equipmentNo: try await equipmentNo, id: id, toPath: DevicePath.absolute(path), autorename: autorename),
            changes: true,
            as: Found.self
        ).entriesVO
    }

    // MARK: - Bytes

    /// Download a file into a temporary file the caller then owns, checked
    /// against the hash the server declared.
    ///
    /// `range` asks for part of it — the server answers 206 to a range — and a
    /// part is not checked: it has no hash of its own.
    public func download(
        _ id: SNFileID,
        range: ClosedRange<Int64>? = nil,
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws -> URL {
        let link = try await call(
            SNPath.deviceDownload, body: ByID(equipmentNo: try await equipmentNo, id: id), changes: false, as: DeviceLink.self
        )
        guard let url = URL(string: link.url) else { throw SNError.malformedResponse("download_v3 link is not a URL") }
        let declared = link.size?.value ?? Transfers.downloadLimit
        if let range, range.lowerBound < 0 || range.upperBound == .max {
            throw SNError.malformedResponse("a byte range must start at zero or later: \(range)")
        }
        let limit = range.map { min($0.upperBound - $0.lowerBound + 1, declared) } ?? declared
        // A private cloud's link to its own storage, onto the address this
        // client was given, as the web API's downloads do.
        return try await Transfers(channel: channel)
            .fetch(url.servedFrom(channel.endpoints.appHost), limit: limit, md5: link.contentHash, range: range, onProgress: onProgress)
    }

    /// Upload a file to `path` — the whole destination, file name included —
    /// and answer with the entry the server made, identifier and all.
    ///
    /// First request `upload/apply` with the file's name,
    /// its size as a number and the **folder** it goes into — `EXPORT/`, no
    /// leading slash, a trailing one; the bytes, by whichever way the answer
    /// names (see `Transfers.send`); and `upload/finish` with the folder again,
    /// the MD5 as `content_hash`, the stored name and the size.
    ///
    /// A tablet against a private server was seen sending the whole destination
    /// to `apply` instead. The official client does not, and this follows it.
    @discardableResult
    public func upload(
        contentsOf file: URL,
        toPath path: String,
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws -> SNDeviceEntry {
        let destination = DevicePath.absolute(path)
        let name = DevicePath.name(of: destination)
        guard !name.isEmpty else { throw SNError.malformedResponse("an upload needs a file name: \(path)") }
        let folder = DevicePath.uploadFolder(of: destination)
        let original = try Original.measure(file, name: name)
        // Every step runs on whichever token the session holds when it runs;
        // a login to another account meanwhile must not have the finish file
        // this account's bytes under that one.
        let login = await session.loginGeneration()
        let slot = try await call(
            SNPath.deviceUploadApply,
            body: Apply(equipmentNo: try await equipmentNo, path: folder, fileName: name, size: original.size),
            changes: false,
            generation: login,
            as: UploadSlot.self
        )
        let signer = channel.s3Signer(session: session, fileServer: slot.fileServer, generation: login)
        let server = FormServer(host: channel.endpoints.appHost, token: try await session.accessToken(forGeneration: login))
        let innerName = try await Transfers(channel: channel)
            .send(original, to: slot, signer: signer, server: server, onProgress: onProgress)
        let entry = try await call(
            SNPath.deviceUploadFinish,
            body: Finish(
                equipmentNo: try await equipmentNo,
                path: folder,
                fileName: name,
                contentHash: original.md5,
                innerName: innerName,
                size: original.size
            ),
            changes: true,
            generation: login,
            as: SNDeviceEntry.self
        )
        Log.supernote.info("uploaded \(original.size, .public) bytes through the device API")
        return entry
    }

    /// The same, for bytes in hand.
    @discardableResult
    public func upload(_ data: Data, toPath path: String) async throws -> SNDeviceEntry {
        let file = try ScratchFile.write(data)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await upload(contentsOf: file, toPath: path)
    }

    // MARK: - The sync lock

    /// Take the account's sync lock, run `body`, and let go — whatever `body`
    /// did.
    ///
    /// The end is sent with `flag: "Y"` when `body` returned and `"N"` when it
    /// threw, as the tablets do. A failure to let go is thrown only when
    /// `body` succeeded; otherwise `body`'s own error is the one that matters,
    /// and the lock lapses on the server's own timer.
    ///
    /// Answers `syncLocked` without running `body` when a device already holds
    /// the lock, or when a client on the same session and with the same
    /// `equipmentNo` is already inside one. Sessions in other processes are
    /// not seen, and neither the reference server nor UltraBridge keeps them
    /// apart. `serverHasData` is what the start said: `false` means the
    /// server holds nothing yet, which is what makes a tablet upload everything.
    public func withSyncLock<T: Sendable>(
        _ body: @Sendable (_ serverHasData: Bool) async throws -> T
    ) async throws -> T {
        // Claimed on the session rather than on this client: the server's lock
        // does not keep two scopes under one name apart — a reference server
        // lets the same `equipmentNo` start again while it holds the lock and
        // releases it on the first end — so every client on this session that
        // shares the name has to be told no here instead.
        let generation = await session.loginGeneration()
        let name = try await equipmentNo
        guard await session.claimSyncLock(for: name) else { throw SNError.syncLocked }
        // Released before this returns or throws, by every route — awaited,
        // not left to a task, so that the next scope on the same name is not
        // told no by a release still in flight.
        do {
            let result = try await lockedScope(body, generation: generation)
            await session.releaseSyncLock(for: name)
            return result
        } catch {
            await session.releaseSyncLock(for: name)
            throw error
        }
    }

    /// The scope itself: start, the body, and an end that is sent whatever
    /// the body did.
    private func lockedScope<T: Sendable>(
        _ body: @Sendable (_ serverHasData: Bool) async throws -> T,
        generation: Int
    ) async throws -> T {
        let started = try await call(
            SNPath.deviceSyncStart, body: Device(equipmentNo: try await equipmentNo), changes: true,
            generation: generation, as: SyncStarted.self
        )
        let result: T
        do {
            result = try await body(started.synType?.value ?? true)
        } catch {
            do {
                // From a task of its own, as the multipart abort is: a
                // cancelled body must still let the lock go.
                try await Task { try await self.endSync(succeeded: false, generation: generation) }.value
            } catch let release {
                Log.supernote.error("the sync lock was not released: \(String(describing: release), .public)")
            }
            throw error
        }
        try await endSync(succeeded: true, generation: generation)
        return result
    }

    private func endSync(succeeded: Bool, generation: Int) async throws {
        _ = try await call(
            SNPath.deviceSyncEnd, body: SyncEnd(equipmentNo: try await equipmentNo, flag: succeeded ? "Y" : "N"),
            changes: true, generation: generation, as: SNChannel.Nothing.self
        )
    }

    // MARK: - Inside

    private func call<Payload: Decodable & Sendable>(
        _ path: String,
        body: some Encodable & Sendable,
        changes: Bool,
        generation: Int? = nil,
        as payload: Payload.Type
    ) async throws -> Payload {
        // Every device-API call is a call of a sync to the official app, and
        // carries `channel`.
        try await channel.call(
            path, on: .app, body: body, by: session, channel: true, changes: changes, generation: generation, as: Payload.self
        )
    }

    private func call(_ path: String, body: some Encodable & Sendable, changes: Bool) async throws {
        _ = try await call(path, body: body, changes: changes, as: SNChannel.Nothing.self)
    }
}

/// Paths as the device API wants them.
enum DevicePath {
    /// With a leading slash, without a trailing one, and without the doubled
    /// slashes a tablet has been seen to send: `/NOTE/Note/x.note`. The top is
    /// `/`.
    static func absolute(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    /// The last component: the file name of a destination.
    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// The folder a destination is in, the way the official app sends it to
    /// `upload/apply` and `upload/finish`: no leading slash, a trailing one —
    /// `EXPORT/`, `NOTE/Note/` — and empty at the top.
    static func uploadFolder(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }
}

// MARK: - Wire shapes

private struct Device: Encodable {
    let equipmentNo: String
}

private struct ListByPath: Encodable {
    let equipmentNo: String
    let path: String
    let recursive: Bool
}

/// The one identifier the device API takes as a **number**: the specification
/// and UltraBridge's DTO both say `Long` here, and UltraBridge, handed a string,
/// lists the root instead. Every other call takes it quoted, as the tablets
/// send it — see `SNFileID`.
private struct ListByID: Encodable {
    let equipmentNo: String
    let id: Int64
    let recursive: Bool
}

private struct ByID: Encodable {
    let equipmentNo: String
    let id: SNFileID
}

private struct ByPath: Encodable {
    let equipmentNo: String
    let path: String
}

private struct CreateFolder: Encodable {
    let equipmentNo: String
    let path: String
    let autorename: Bool
}

private struct Relocate: Encodable {
    let equipmentNo: String
    let id: SNFileID
    let toPath: String
    let autorename: Bool

    enum CodingKeys: String, CodingKey {
        case equipmentNo, id, autorename
        case toPath = "to_path"
    }
}

/// `size` a number, as the official app sends it.
private struct Apply: Encodable {
    let equipmentNo: String
    let path: String
    let fileName: String
    let size: Int64
}

/// The finish request sends a numeric `size` and a snake-case `content_hash`.
private struct Finish: Encodable {
    let equipmentNo: String
    let path: String
    let fileName: String
    let contentHash: String
    let innerName: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case equipmentNo, path, fileName, innerName, size
        case contentHash = "content_hash"
    }
}

private struct SyncEnd: Encodable {
    let equipmentNo: String
    let flag: String
}

private struct Listing: Decodable {
    let entries: [SNDeviceEntry]?
}

private struct Found: Decodable {
    let entriesVO: SNDeviceEntry?
}

private struct Created: Decodable {
    let metadata: SNDeviceEntry?
}

private struct DeviceLink: Decodable {
    let url: String
    let contentHash: String?
    let size: WireInt64?

    enum CodingKeys: String, CodingKey {
        case url, size
        case contentHash = "content_hash"
    }
}

private struct SyncStarted: Decodable {
    let synType: WireFlag?
}
