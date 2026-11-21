// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Synchronization
import Testing

// The recycle bin, the folder-only listing and the PNG export, on the web host.

@Test("The recycle bin is read page by page; a date comes as milliseconds or as Jackson's ISO string")
func listsTheRecycleBin() async throws {
    let transport = ScriptedTransport([
        .ok(#"""
        "total":2,"recycleFileVOList":[
         {"fileId":"900000000000000007","isFolder":"N","fileName":"sample.bin","size":1024,"updateTime":946684802000},
         {"fileId":"77","isFolder":"Y","fileName":"Old","size":0,"updateTime":"2000-01-01T00:00:00.000+0000"}]
        """#),
    ])
    let (client, _, _) = loggedInClient(transport)

    let bin = try await client.recycleBin()

    let call = try #require(transport.calls.first)
    #expect(call.url?.absoluteString == "https://cloud.supernote.com/api/file/recycle/list/query")
    #expect(call.value(forHTTPHeaderField: "X-XSRF-TOKEN") == "xsrf-1")
    #expect(call.jsonBody["order"] as? String == "time")
    #expect(call.jsonBody["sequence"] as? String == "desc")
    #expect(call.jsonBody["pageNo"] as? Int == 1)
    #expect(call.jsonBody["pageSize"] as? Int == 100)
    #expect(bin == [
        SNRecycledEntry(
            id: SNFileID(rawValue: 900_000_000_000_000_007), name: "sample.bin", isFolder: false, size: 1024,
            deleted: Date(timeIntervalSince1970: 946_684_802)
        ),
        SNRecycledEntry(id: SNFileID(rawValue: 77), name: "Old", isFolder: true, deleted: Date(timeIntervalSince1970: 946_684_800)),
    ])
}

@Test("Restoring, deleting for good and emptying name the entries by the identifiers they had")
func changesTheRecycleBin() async throws {
    let transport = ScriptedTransport([.ok(), .ok(), .ok(), .refused("E0311"), .refused("E0301")])
    let (client, _, _) = loggedInClient(transport)
    let ids = [SNFileID(rawValue: 5), SNFileID(rawValue: 6)]

    try await client.restore(ids)
    try await client.deleteForever(ids)
    try await client.emptyRecycleBin()
    await #expect(throws: SNError.notFound(code: "E0311")) { try await client.restore(ids) }
    await #expect(throws: SNError.syncLocked) { try await client.restore(ids) }
    try await client.restore([])

    #expect(transport.calls.map { $0.url?.path } == [
        "/api/file/recycle/revert", "/api/file/recycle/delete", "/api/file/recycle/clear",
        "/api/file/recycle/revert", "/api/file/recycle/revert",
    ])
    #expect(transport.calls[0].jsonBody["idList"] as? [String] == ["5", "6"])
    #expect(transport.calls[1].jsonBody["idList"] as? [String] == ["5", "6"])
    #expect(transport.calls[2].jsonBody.isEmpty)
}

@Test("Folders only: the list of exclusions is never empty, and `empty` speaks of subfolders")
func listsFoldersOnly() async throws {
    let transport = ScriptedTransport([
        .ok(#"""
        "folderVOList":[{"id":"11","directoryId":"0","fileName":"Note","empty":"N"},
         {"id":"12","directoryId":"0","fileName":"Inbox","empty":"Y"}]
        """#),
        .ok(#""folderVOList":[]"#),
    ])
    let (client, _, _) = loggedInClient(transport)

    let top = try await client.folders()
    #expect(top == [
        SNFolder(id: SNFileID(rawValue: 11), parentID: .root, name: "Note", hasSubfolders: true),
        SNFolder(id: SNFileID(rawValue: 12), parentID: .root, name: "Inbox", hasSubfolders: false),
    ])
    #expect(transport.calls[0].url?.path == "/api/file/folder/list/query")
    #expect(transport.calls[0].jsonBody["directoryId"] as? String == "0")
    #expect(transport.calls[0].jsonBody["idList"] as? [String] == ["0"])

    _ = try await client.folders(in: SNFileID(rawValue: 11), excluding: [SNFileID(rawValue: 13)])
    #expect(transport.calls[1].jsonBody["idList"] as? [String] == ["13"])
}

private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

@Test("A note's pages come back as PNG files, in page order, each held to the PNG signature")
func exportsANoteAsPNGs() async throws {
    let transport = ScriptedTransport([
        .ok(#""pngPageVOList":[{"pageNo":2,"url":"https://storage.example.com/p2"},{"pageNo":1,"url":"https://storage.example.com/p1"}]"#),
        .init(headers: ["Content-Type": "image/png"], bytes: pngSignature + Data("one".utf8)),
        .init(headers: ["Content-Type": "image/png"], bytes: pngSignature + Data("two".utf8)),
    ])
    let (client, _, _) = loggedInClient(transport)

    let files = try await client.pngs(ofNote: SNFileID(rawValue: 42))
    defer { for file in files { try? FileManager.default.removeItem(at: file) } }

    #expect(transport.calls[0].url?.path == "/api/file/note/to/png")
    #expect(transport.calls[0].jsonBody["id"] as? String == "42")
    #expect(transport.calls[1].url?.path == "/p1")
    #expect(transport.calls[1].value(forHTTPHeaderField: "x-access-token") == nil)
    #expect(try files.map { try Data(contentsOf: $0) } == [pngSignature + Data("one".utf8), pngSignature + Data("two".utf8)])
}

@Test("A page that is not a PNG fails the export and leaves no file behind")
func refusesAPageThatIsNotAPNG() async throws {
    let transport = ScriptedTransport([
        .ok(#""pngPageVOList":[{"pageNo":1,"url":"https://storage.example.com/p1"},{"pageNo":2,"url":"https://storage.example.com/p2"}]"#),
        .init(headers: ["Content-Type": "image/png"], bytes: pngSignature),
        .init(body: "<Error><Code>AccessDenied</Code></Error>", headers: ["Content-Type": "application/xml"]),
    ])
    let (client, _, _) = loggedInClient(transport)

    await #expect(throws: SNError.self) { _ = try await client.pngs(ofNote: SNFileID(rawValue: 42)) }

    // Asked of the files this export wrote, not of the shared temporary
    // directory, which the suites running beside it write into too.
    #expect(transport.downloadedFiles.count == 2)
    #expect(transport.downloadedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
}

@Test("An export that names no pages is not taken for an empty note")
func refusesAnExportWithNoPages() async throws {
    let transport = ScriptedTransport([.ok(#""pngPageVOList":[]"#)])
    let (client, _, _) = loggedInClient(transport)
    await #expect(throws: SNError.malformedResponse("note/to/png named no pages")) {
        _ = try await client.pngs(ofNote: SNFileID(rawValue: 42))
    }
}

@Test("A note still being converted is waited for, then exported")
func waitsOutAConversionInProgress() async throws {
    let sleeper = RecordingSleeper()
    let transport = ScriptedTransport([
        .refused("E0316", "This file is being converted"),
        .refused("E0316", "This file is being converted"),
        .ok(#""pngPageVOList":[{"pageNo":1,"url":"https://storage.example.com/p1"}]"#),
        .init(headers: ["Content-Type": "image/png"], bytes: pngSignature),
    ])
    let (client, _, _) = loggedInClient(transport, sleeper: sleeper)

    let files = try await client.pngs(ofNote: SNFileID(rawValue: 42))
    defer { for file in files { try? FileManager.default.removeItem(at: file) } }

    #expect(files.count == 1)
    #expect(sleeper.delays == [.seconds(5), .seconds(5)])
}

@Test("A conversion that never finishes is given up on after the conversion's own time limit")
func givesUpOnAConversionThatNeverEnds() async throws {
    let sleeper = RecordingSleeper()
    let transport = ScriptedTransport(Array(repeating: .refused("E0316", "This file is being converted"), count: 61))
    let (client, _, _) = loggedInClient(transport, sleeper: sleeper)

    await #expect(throws: SNError.rejected(code: "E0316", message: "This file is being converted")) {
        _ = try await client.pngs(ofNote: SNFileID(rawValue: 42))
    }
    #expect(sleeper.delays.count == 60)
    #expect(transport.calls.count == 61)
}

@Test("A repeated identifier is sent once: the service would read it as an entry gone from the bin")
func sendsEachIdentifierOnce() async throws {
    let transport = ScriptedTransport([.ok(), .ok()])
    let (client, _, _) = loggedInClient(transport)
    try await client.restore([SNFileID(rawValue: 5), SNFileID(rawValue: 6), SNFileID(rawValue: 5)])
    try await client.deleteForever([SNFileID(rawValue: 7), SNFileID(rawValue: 7)])
    #expect(Set(transport.calls[0].jsonBody["idList"] as? [String] ?? []) == ["5", "6"])
    #expect((transport.calls[0].jsonBody["idList"] as? [String])?.count == 2)
    #expect(transport.calls[1].jsonBody["idList"] as? [String] == ["7"])
}

@Test("A private cloud's link to its own storage is moved onto the address this client was given")
func movesOwnStorageLinksOntoTheConfiguredHost() async throws {
    let transport = ScriptedTransport([
        .ok(#""pngPageVOList":[{"pageNo":1,"url":"http://172.17.0.2:19071/api/oss/download?path=x&signature=s"}]"#),
        .init(headers: ["Content-Type": "image/png"], bytes: pngSignature),
    ])
    let (client, _, _) = loggedInClient(transport, endpoints: .privateCloud(URL.constant("http://nas.local:8080")))

    let files = try await client.pngs(ofNote: SNFileID(rawValue: 42))
    defer { for file in files { try? FileManager.default.removeItem(at: file) } }

    let page = try #require(transport.calls.last?.url)
    #expect(page.absoluteString == "http://nas.local:8080/api/oss/download?path=x&signature=s")
    #expect(URL.constant("https://bucket.s3.amazonaws.com/api/oss/x").servedFrom(URL.constant("http://nas.local:8080")).host() == "nas.local")
    #expect(URL.constant("https://bucket.s3.amazonaws.com/key").servedFrom(URL.constant("http://nas.local:8080")).host() == "bucket.s3.amazonaws.com")
}

@Test("Export progress moves forward by pages, whatever each page weighs")
func reportsProgressByPages() async throws {
    let transport = ScriptedTransport([
        .ok(#""pngPageVOList":[{"pageNo":1,"url":"https://storage.example.com/p1"},{"pageNo":2,"url":"https://storage.example.com/p2"}]"#),
        .init(headers: ["Content-Type": "image/png"], bytes: pngSignature + Data(count: 5_000)),
        .init(headers: ["Content-Type": "image/png"], bytes: pngSignature),
    ])
    let (client, _, _) = loggedInClient(transport)
    let seen = Mutex<[(Int64, Int64)]>([])

    let files = try await client.pngs(ofNote: SNFileID(rawValue: 42)) { done, total in seen.withLock { $0.append((done, total)) } }
    defer { for file in files { try? FileManager.default.removeItem(at: file) } }

    let reports = seen.withLock { $0 }
    #expect(reports.map(\.0) == [1_000, 2_000])
    #expect(reports.allSatisfy { $0.1 == 2_000 })
}
