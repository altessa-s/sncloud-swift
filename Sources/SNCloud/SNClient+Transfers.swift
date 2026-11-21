// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// The bytes, by identifier: down by a signed URL, up through `upload/apply`.
/// How they travel is `Transfers`'s; what is here is the web API's own calls.
extension SNClient {
    /// The ceiling on a download whose size nobody declared.
    public static var downloadLimit: Int64 { Transfers.downloadLimit }

    /// How long a note may take to become a PDF. The conversion is done on the
    /// server while the request waits, and a long notebook takes minutes.
    static let conversionTimeout: TimeInterval = 300

    var transfers: Transfers { Transfers(channel: channel) }

    // MARK: - Down

    /// Download a file into a temporary file the caller then owns.
    ///
    /// The service answers with a signed storage URL and the content's MD5; the
    /// bytes come from storage, with no token on the request, and are checked
    /// against the MD5 before anybody sees them. That check is not a formality:
    /// a signed URL that has expired has been seen to answer 200 with an XML
    /// error document, which would otherwise arrive as the file.
    ///
    /// `size`, when the caller knows it from a listing, is the ceiling the
    /// transfer is held to.
    public func download(
        _ id: SNFileID,
        expecting size: Int64? = nil,
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws -> URL {
        let link = try await authorized(
            SNPath.downloadURL, body: DownloadRequest(id: id, type: 0), changes: false, as: Link.self
        )
        guard let url = URL(string: link.url) else { throw SNError.malformedResponse("download link is not a URL") }
        return try await transfers.fetch(
            url.servedFrom(channel.endpoints.webHost), limit: size ?? Transfers.downloadLimit, md5: link.md5, onProgress: onProgress
        )
    }

    /// The same, for an entry from a listing: its size is already known.
    public func download(_ entry: SNEntry, onProgress: @escaping TransferProgress = { _, _ in }) async throws -> URL {
        try await download(entry.id, expecting: entry.size, onProgress: onProgress)
    }

    /// A note rendered as a PDF by the service, into a temporary file.
    ///
    /// `pages` empty means every page — and is the safe default: a list that
    /// does not match the note is refused with "The QT program failed to parse
    /// the file!".
    public func pdf(
        ofNote id: SNFileID,
        pages: [Int] = [],
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws -> URL {
        let link = try await authorized(
            SNPath.noteToPDF,
            body: ConversionRequest(id: id, pageNoList: pages, type: 0),
            changes: false,
            timeout: Self.conversionTimeout,
            as: Link.self
        )
        guard let url = URL(string: link.url) else { throw SNError.malformedResponse("PDF link is not a URL") }
        return try await transfers.fetch(
            url.servedFrom(channel.endpoints.webHost), limit: Transfers.downloadLimit, md5: link.md5, onProgress: onProgress
        )
    }

    /// A note rendered page by page as PNG images by the service, each into a
    /// temporary file the caller then owns, in page order.
    ///
    /// The service gives no hash for the images, so each is held to the PNG
    /// signature instead: an expired link's XML error is not taken for a page.
    /// A note being converted already — by another call, from anywhere, or by
    /// this one's own first attempt that the network cut off — is answered
    /// `E0316` until that conversion is done; this waits it out, up to the
    /// conversion's own time limit. Anything but a `.note` is `E0315`.
    ///
    /// Progress counts pages: each page is an equal share, whatever its bytes.
    public func pngs(
        ofNote id: SNFileID,
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws -> [URL] {
        let pages = try await convertedPages(of: id).sorted { ($0.pageNo ?? 0) < ($1.pageNo ?? 0) }
        // A note has a page at least; an answer with none is not an export.
        guard !pages.isEmpty else { throw SNError.malformedResponse("note/to/png named no pages") }
        var files: [URL] = []
        do {
            let share: Int64 = 1_000
            let whole = share * Int64(pages.count)
            for (index, page) in pages.enumerated() {
                guard let url = URL(string: page.url ?? "") else { throw SNError.malformedResponse("PNG link is not a URL") }
                let served = url.servedFrom(channel.endpoints.webHost)
                let file = try await transfers.fetch(served, limit: Transfers.downloadLimit, md5: nil) { done, total in
                    let within = total > 0 ? min(done, total) * share / total : 0
                    onProgress(Int64(index) * share + within, whole)
                }
                files.append(file)
                try Self.checkPNG(file)
            }
        } catch {
            for file in files { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        return files
    }

    /// How long to wait between asking again while the service says the note
    /// is still being converted.
    static let conversionPoll: Duration = .seconds(5)

    /// The pages `note/to/png` names, asked again while it answers `E0316`.
    ///
    /// The limit holds twice over: on the waits between asks, and on the
    /// clock, which also counts the time the asks themselves took.
    private func convertedPages(of id: SNFileID) async throws -> [PNGPage] {
        let limit = Duration.seconds(Int(Self.conversionTimeout))
        let started = ContinuousClock.now
        var waited: Duration = .zero
        while true {
            do {
                return try await authorized(
                    SNPath.noteToPNG, body: IDRequest(id: id), changes: false, timeout: Self.conversionTimeout, as: PNGAnswer.self
                ).pngPageVOList ?? []
            } catch SNError.rejected(code: "E0316", message: _) where waited < limit && ContinuousClock.now - started < limit {
                try await channel.sleeper.sleep(for: Self.conversionPoll)
                waited += Self.conversionPoll
            }
        }
    }

    /// The eight bytes every PNG begins with.
    static func checkPNG(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 8) ?? Data()
        guard head == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw SNError.malformedResponse("a page is not a PNG: \(SNError.shape(of: head))")
        }
    }

    // MARK: - Up

    /// Upload a file into `folder`, under `name` or its own.
    ///
    /// Three steps: ask for somewhere to put the bytes, put them there, and say
    /// they are there. The middle one differs by server, and the first answer
    /// says which — see `Transfers.send`.
    ///
    /// The web API does not answer an upload with the new file's identifier;
    /// `entry(named:in:)` finds it, and `SNDeviceClient.upload` answers with it.
    public func upload(
        contentsOf file: URL,
        named name: String? = nil,
        to folder: SNFileID = .root,
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws {
        let original = try Original.measure(file, name: name ?? file.lastPathComponent)
        // See `SNDeviceClient.upload`: one account from apply to finish.
        let login = await session.loginGeneration()
        let slot = try await authorized(
            SNPath.uploadApply,
            body: ApplyRequest(directoryId: folder, fileName: original.name, md5: original.md5, size: original.size),
            changes: false,
            generation: login,
            as: UploadSlot.self
        )
        let signer = channel.s3Signer(session: session, fileServer: slot.fileServer, generation: login)
        let server = FormServer(host: channel.endpoints.webHost, token: try await session.accessToken(forGeneration: login))
        let innerName = try await transfers.send(original, to: slot, signer: signer, server: server, onProgress: onProgress)
        try await authorized(
            SNPath.uploadFinish,
            body: FinishRequest(
                directoryId: folder,
                fileName: original.name,
                fileSize: original.size,
                md5: original.md5,
                innerName: innerName,
                type: "2"
            ),
            changes: true,
            generation: login
        )
        Log.supernote.info("uploaded \(original.size, .public) bytes")
    }

    /// The same, for bytes in hand.
    public func upload(_ data: Data, named name: String, to folder: SNFileID = .root) async throws {
        let file = try ScratchFile.write(data)
        defer { try? FileManager.default.removeItem(at: file) }
        try await upload(contentsOf: file, named: name, to: folder)
    }
}

// MARK: - Wire shapes

private struct DownloadRequest: Encodable {
    let id: SNFileID
    let type: Int
}

private struct ConversionRequest: Encodable {
    let id: SNFileID
    let pageNoList: [Int]
    let type: Int
}

private struct Link: Decodable {
    let url: String
    let md5: String?
}

private struct PNGAnswer: Decodable {
    let pngPageVOList: [PNGPage]?
}

private struct PNGPage: Decodable {
    let pageNo: Int?
    let url: String?
}

private struct ApplyRequest: Encodable {
    let directoryId: SNFileID
    let fileName: String
    let md5: String
    let size: Int64
}

private struct FinishRequest: Encodable {
    let directoryId: SNFileID
    let fileName: String
    let fileSize: Int64
    let md5: String
    let innerName: String
    let type: String
}
