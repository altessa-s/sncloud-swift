// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One file or folder as the device API names it: by path, with its content's
/// hash beside it.
///
/// Not an `SNEntry`, because the two APIs do not describe the same tree the
/// same way. The web API flattens the top of it — `Note`, `Document` — while
/// the device API shows what the server stores — `NOTE/Note`, `DOCUMENT/Document`
/// — and a path from one is not a path in the other. The identifiers are the
/// same snowflakes in both.
public struct SNDeviceEntry: Sendable, Equatable, Identifiable {
    public let id: SNFileID
    public let name: String
    /// The whole path from the root, without a leading slash:
    /// `NOTE/Note/Meeting.note`. Worked out, not copied — see `pathDisplay`.
    public let path: String
    /// The folder it is in, without a leading slash: `NOTE/Note`, and empty at
    /// the top. `nil` where the answer gives no way to tell.
    public let parentPath: String?
    /// `path_display` exactly as the server sent it.
    ///
    /// Kept because it does not mean one thing. On the official cloud a
    /// `list_folder` entry carries the **folder it is in** — `/NOTE/Note` from a
    /// recursive listing of the root, `INBOX` from a listing of `/INBOX`, empty
    /// at the top — while `download_v3` carries the **whole path**,
    /// `NOTE/Note/Sample.note`. UltraBridge answers the whole path
    /// everywhere. The slash says nothing; what does is the last component: a
    /// whole path ends in the entry's own name, a folder does not.
    ///
    /// The one case that rule reads wrong is an entry named like the folder it
    /// is in — `Foo/Foo` listed as `Foo` — which is read as a whole path one
    /// level too high.
    public let pathDisplay: String
    public let isFolder: Bool
    /// Bytes; `nil` for a folder and where the server did not say.
    public let size: Int64?
    /// The content's MD5, lowercase hex.
    public let contentHash: String?
    public let modified: Date?
    /// Whether the server will hand out a download link for it.
    public let isDownloadable: Bool?

    public init(
        id: SNFileID,
        name: String,
        path: String,
        parentPath: String? = nil,
        pathDisplay: String? = nil,
        isFolder: Bool,
        size: Int64? = nil,
        contentHash: String? = nil,
        modified: Date? = nil,
        isDownloadable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.pathDisplay = pathDisplay ?? path
        self.isFolder = isFolder
        self.size = size
        self.contentHash = contentHash
        self.modified = modified
        self.isDownloadable = isDownloadable
    }
}

extension SNDeviceEntry: Decodable {
    private enum Keys: String, CodingKey {
        case tag, id, name
        case path = "path_display"
        case parentPath = "parent_path"
        case contentHash = "content_hash"
        case size, lastUpdateTime
        case isDownloadable = "is_downloadable"
        // Ratta's own server answers with this spelling; its specification
        // and every re-implementation say `is_downloadable`.
        case bareDownloadable = "_downloadable"
    }

    /// `EntriesVO` and the thinner `MetadataVO` alike: the second is the first
    /// without a hash, a size or a time.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(SNFileID.self, forKey: .id)
        let display = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        pathDisplay = display
        let declaredName = try container.decodeIfPresent(String.self, forKey: .name)
        let declaredParent = try container.decodeIfPresent(String.self, forKey: .parentPath)
        let place = Self.place(display: display, name: declaredName, parent: declaredParent)
        name = place.name
        path = place.path
        parentPath = place.parent
        isFolder = try container.decodeIfPresent(String.self, forKey: .tag)?.lowercased() == "folder"
        size = try? container.decodeIfPresent(WireInt64.self, forKey: .size)?.value
        let hash = try container.decodeIfPresent(String.self, forKey: .contentHash)?.lowercased()
        contentHash = hash?.isEmpty == true ? nil : hash
        modified = container.milliseconds(.lastUpdateTime)
        isDownloadable = (try? container.decodeIfPresent(WireFlag.self, forKey: .isDownloadable))?.value
            ?? (try? container.decodeIfPresent(WireFlag.self, forKey: .bareDownloadable))?.value
    }

    /// The same entry, read as one listed in `folder` — which a listing of
    /// that folder knows for certain, and the rule in `place` can only guess.
    /// It settles the one case the guess gets wrong: `Foo` listed in `Foo`.
    func listed(in folder: String) -> SNDeviceEntry {
        let folder = folder.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        let display = pathDisplay.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        guard display == folder, !name.isEmpty else { return self }
        return SNDeviceEntry(
            id: id,
            name: name,
            path: folder.isEmpty ? name : "\(folder)/\(name)",
            parentPath: folder,
            pathDisplay: pathDisplay,
            isFolder: isFolder,
            size: size,
            contentHash: contentHash,
            modified: modified,
            isDownloadable: isDownloadable
        )
    }

    /// Name, whole path and folder, from whichever of them the answer spelled
    /// out. See `pathDisplay` for what the slash means.
    static func place(display: String, name: String?, parent: String?) -> (name: String, path: String, parent: String?) {
        func trimmed(_ text: String) -> String {
            text.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        }
        let lastOfDisplay = display.split(separator: "/").last.map(String.init)
        let isFolderOfEntry = display.isEmpty || (name != nil && lastOfDisplay != name)
        if isFolderOfEntry, let name {
            let folder = trimmed(display)
            return (name, folder.isEmpty ? name : "\(folder)/\(name)", folder)
        }
        let whole = trimmed(display)
        let last = whole.split(separator: "/").last.map(String.init) ?? ""
        let folder = parent.map(trimmed) ?? (whole.contains("/") ? String(whole[..<(whole.lastIndex(of: "/") ?? whole.endIndex)]) : "")
        return (name ?? last, whole.isEmpty ? (name ?? "") : whole, folder)
    }
}

/// The device API's word for the account's storage: what is used, and what the
/// plan allocates.
public struct SNSpaceUsage: Sendable, Equatable {
    public let used: Int64
    public let allocated: Int64?

    public init(used: Int64, allocated: Int64?) {
        self.used = used
        self.allocated = allocated
    }
}

extension SNSpaceUsage: Decodable {
    private enum Keys: String, CodingKey {
        case used, allocationVO
    }

    private enum AllocationKeys: String, CodingKey {
        case allocated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        used = try container.decode(WireInt64.self, forKey: .used).value
        let allocation = try? container.nestedContainer(keyedBy: AllocationKeys.self, forKey: .allocationVO)
        allocated = try? allocation?.decodeIfPresent(WireInt64.self, forKey: .allocated)?.value
    }
}
