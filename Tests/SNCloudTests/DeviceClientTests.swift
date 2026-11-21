// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Testing

// Synthetic device listings cover both supported path representations.

/// The installation every suite here is: a fixed UUID, so the device's names
/// can be written down.
let testClientID = "48ab5202-196e-4525-9694-72fbab06f06e"
let testEquipmentNo = "\(SNDeviceIdentity.currentPlatform)-\(testClientID)"

private func deviceClient(
    _ transport: ScriptedTransport,
    endpoints: SNEndpoints = .official
) -> (SNDeviceClient, InMemorySecrets) {
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com", .clientID: testClientID])
    let session = SNSession(endpoints: endpoints, transport: transport, secrets: secrets, sleeper: RecordingSleeper())
    return (SNDeviceClient(session: session), secrets)
}

private let noteEntry = #"""
{"tag":"file","id":"900000000000000005","name":"Sample.note","path_display":"NOTE/Note/Sample.note",
 "content_hash":"20439F79E4E9DC95BE34B21029221F80","size":4096,"lastUpdateTime":946685000000,
 "_downloadable":true,"parent_path":"/NOTE/Note"}
"""#

@Test("The whole tree comes in one listing, flat")
func listsTheTreeByPath() async throws {
    let transport = ScriptedTransport([
        .ok(#""equipmentNo":"WEB","entries":[{"tag":"folder","id":"5","name":"Note","path_display":"NOTE/Note"},\#(noteEntry)]"#),
    ])
    let (client, _) = deviceClient(transport)

    let entries = try await client.list(path: "/", recursive: true)

    let call = try #require(transport.calls.first)
    #expect(call.url?.absoluteString == "https://viewer.supernote.com/api/file/2/files/list_folder")
    #expect(call.jsonBody["path"] as? String == "/")
    #expect(call.jsonBody["recursive"] as? Bool == true)
    #expect(call.jsonBody["equipmentNo"] as? String == testEquipmentNo)
    #expect(call.value(forHTTPHeaderField: "x-access-token") == liveToken)
    // The official app's headers: the device with an underscore, the protocol
    // version, and `channel` — and no XSRF pair on the apps' host.
    #expect(call.value(forHTTPHeaderField: "equipmentNo") == "\(SNDeviceIdentity.currentPlatform)_\(testClientID)")
    #expect(call.value(forHTTPHeaderField: "version") == "202407")
    let channel = try #require(call.value(forHTTPHeaderField: "channel"))
    #expect(channel.hasPrefix("\(liveToken)_\(SNDeviceIdentity.currentPlatform)\(testClientID)_"))
    #expect(Int64(channel.split(separator: "_").last ?? "") != nil)
    #expect(call.value(forHTTPHeaderField: "X-XSRF-TOKEN") == nil)
    #expect(call.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(transport.handshakes == 0)

    #expect(entries.count == 2)
    #expect(entries[0].isFolder)
    let note = entries[1]
    #expect(note.id.rawValue == 900_000_000_000_000_005)
    #expect(note.path == "NOTE/Note/Sample.note")
    #expect(note.parentPath == "NOTE/Note")
    #expect(note.contentHash == "20439f79e4e9dc95be34b21029221f80")
    #expect(note.size == 4_096)
    #expect(note.modified == Date(timeIntervalSince1970: 946_685_000))
    // Ratta's server spells it with a leading underscore.
    #expect(note.isDownloadable == true)
}

@Test("A path is sent with one leading slash and no doubled ones")
func normalisesPaths() {
    #expect(DevicePath.absolute("NOTE//Note/") == "/NOTE/Note")
    #expect(DevicePath.absolute("") == "/")
    #expect(DevicePath.uploadFolder(of: "/INBOX/test_document.pdf") == "INBOX/")
    #expect(DevicePath.uploadFolder(of: "/NOTE/Note/x.note") == "NOTE/Note/")
    #expect(DevicePath.uploadFolder(of: "/top.pdf").isEmpty)
    #expect(DevicePath.name(of: "/NOTE/Note/x.note") == "x.note")
}

@Test("A missing entry is nil, not an error")
func answersAMissingEntryWithNil() async throws {
    let transport = ScriptedTransport([.ok(#""equipmentNo":null,"entriesVO":null"#), .ok(#""entriesVO":\#(noteEntry)"#)])
    let (client, _) = deviceClient(transport)

    #expect(try await client.entry(atPath: "/NOTE/Note/Nothing.note") == nil)
    let found = try await client.entry(SNFileID(rawValue: 900_000_000_000_000_005))
    #expect(found?.name == "Sample.note")
    // The tablets send the identifier quoted, and a server written in Go refuses
    // it any other way.
    #expect(transport.calls[1].jsonBody["id"] as? String == "900000000000000005")
}

@Test("A new folder answers with its identifier")
func createsAFolder() async throws {
    let transport = ScriptedTransport([
        .ok(#""metadata":{"tag":"folder","id":"77","name":"Projects","path_display":"NOTE/Note/Projects"}"#),
    ])
    let (client, _) = deviceClient(transport)

    let folder = try await client.createFolder(atPath: "NOTE/Note/Projects")

    #expect(folder.id == SNFileID(rawValue: 77))
    #expect(folder.isFolder)
    #expect(transport.calls[0].jsonBody["path"] as? String == "/NOTE/Note/Projects")
    #expect(transport.calls[0].jsonBody["autorename"] as? Bool == false)
}

@Test("A move names the whole destination, new name included")
func movesToAFullPath() async throws {
    let transport = ScriptedTransport([.ok(#""entriesVO":\#(noteEntry)"#)])
    let (client, _) = deviceClient(transport)
    try await client.move(SNFileID(rawValue: 862), toPath: "/NOTE/Note/Renamed.note")
    let body = transport.calls[0].jsonBody
    #expect(transport.calls[0].url?.path == "/api/file/3/files/move_v3")
    #expect(body["to_path"] as? String == "/NOTE/Note/Renamed.note")
    #expect(body["id"] as? String == "862")
}

@Test("An upload names its folder to apply and to finish, as the official app does")
func uploadsLikeATablet() async throws {
    let transport = ScriptedTransport([
        .ok(#""equipmentNo":"WEB","innerName":"stored.pdf","fullUploadUrl":"http://nas.local/api/oss/upload?signature=s&path=p","xamzDate":"1773292687879""#),
        .ok(#""innerName":null,"md5":null"#),
        .ok(
            #""equipmentNo":"WEB","path_display":"INBOX/test_document.pdf","id":"4242","size":15,"name":"test_document.pdf","#
                + #""content_hash":"5b5778d47e5d7cc586801850e65f0d0b""#
        ),
    ])
    let (client, _) = deviceClient(transport, endpoints: .privateCloud(.constant("http://nas.local")))

    let entry = try await client.upload(Data("hello supernote".utf8), toPath: "/INBOX/test_document.pdf")

    let apply = transport.calls[0].jsonBody
    #expect(transport.calls[0].url?.path == "/api/file/3/files/upload/apply")
    #expect(apply["path"] as? String == "INBOX/")
    #expect(apply["fileName"] as? String == "test_document.pdf")
    #expect(apply["size"] as? Int == 15, "the apply sends its size as a number")

    #expect(transport.calls[1].url?.path == "/api/oss/upload")

    let finish = transport.calls[2].jsonBody
    #expect(transport.calls[2].url?.path == "/api/file/2/files/upload/finish")
    #expect(finish["path"] as? String == "INBOX/")
    #expect(finish["fileName"] as? String == "test_document.pdf")
    #expect(finish["content_hash"] as? String == "5b5778d47e5d7cc586801850e65f0d0b")
    #expect(finish["innerName"] as? String == "stored.pdf")
    #expect(finish["size"] as? Int == 15, "the official app sends the finish's size as a number")

    #expect(entry.id == SNFileID(rawValue: 4242))
    #expect(entry.path == "INBOX/test_document.pdf")
}

@Test("A download is checked against the content hash; a range is not")
func downloadsByHashAndRange() async throws {
    let link = #""url":"http://nas.local/api/oss/download?path=p&signature=s","content_hash":"5b5778d47e5d7cc586801850e65f0d0b","size":15"#
    let transport = ScriptedTransport([
        .ok(link),
        .init(body: "hello supernote", headers: ["Content-Type": "application/octet-stream"]),
        .ok(link),
        .init(status: 206, body: "hello", headers: ["Content-Type": "application/octet-stream", "Content-Range": "bytes 0-4/15"]),
    ])
    let (client, _) = deviceClient(transport)

    let whole = try await client.download(SNFileID(rawValue: 1))
    defer { try? FileManager.default.removeItem(at: whole) }
    #expect(try Data(contentsOf: whole) == Data("hello supernote".utf8))

    let part = try await client.download(SNFileID(rawValue: 1), range: 0...4)
    defer { try? FileManager.default.removeItem(at: part) }
    #expect(try Data(contentsOf: part) == Data("hello".utf8))
    #expect(transport.calls[3].value(forHTTPHeaderField: "Range") == "bytes=0-4")
    #expect(transport.calls[3].value(forHTTPHeaderField: "x-access-token") == nil)
}

@Test("The sync lock is released whatever the body did")
func releasesTheSyncLock() async throws {
    let transport = ScriptedTransport([.ok(#""equipmentNo":"Mac-1","synType":false"#), .ok(), .ok(#""synType":true"#), .ok()])
    let (client, _) = deviceClient(transport)

    let saw = try await client.withSyncLock { serverHasData in serverHasData }
    #expect(saw == false)
    #expect(transport.calls.map(\.url?.path) == ["/api/file/2/files/synchronous/start", "/api/file/2/files/synchronous/end"])
    #expect(transport.calls[1].jsonBody["flag"] as? String == "Y")
    #expect(transport.calls[1].jsonBody["equipmentNo"] as? String == testEquipmentNo)

    struct Failed: Error {}
    await #expect(throws: Failed.self) {
        try await client.withSyncLock { _ in throw Failed() }
    }
    #expect(transport.calls.last?.jsonBody["flag"] as? String == "N")
}

@Test("A lock another device holds is reported, whatever status it came with")
func reportsAHeldLock() async throws {
    // One server answers 200 and E0078, another 409 and E0078.
    for status in [200, 409] {
        let transport = ScriptedTransport([
            .init(status: status, body: #"{"success":false,"errorCode":"E0078","errorMsg":"Another device is synchronizing"}"#),
        ])
        let (client, _) = deviceClient(transport)
        await #expect(throws: SNError.syncLocked) {
            try await client.withSyncLock { _ in () }
        }
        #expect(transport.calls.count == 1, "the body ran without the lock")
    }
}

@Test("A 5xx with a code beside it is still a 5xx, and is retried")
func keepsA5xxRetryable() async throws {
    let transport = ScriptedTransport([
        .init(status: 503, body: #"{"success":false,"errorCode":"E9999","errorMsg":"busy"}"#),
        .ok(#""used":1024,"allocationVO":{"tag":"personal","allocated":"4096"}"#),
    ])
    let (client, _) = deviceClient(transport)
    #expect(try await client.spaceUsage() == SNSpaceUsage(used: 1024, allocated: 4096))
    #expect(transport.calls.count == 2)
}

@Test("The device API drops a refused token the same way the web API does")
func dropsARefusedTokenOnTheDeviceAPI() async throws {
    let transport = ScriptedTransport([.refused("E0712")])
    let (client, secrets) = deviceClient(transport)
    await #expect(throws: SNError.sessionExpired) { _ = try await client.list() }
    #expect(try secrets.secret(.accessToken) == nil)
}

@Test("A folder listed by identifier names it as a number")
func listsAFolderByNumber() async throws {
    // The one place the device API takes an identifier unquoted: the
    // specification and UltraBridge say Long, and UltraBridge lists the root
    // when handed a string.
    let transport = ScriptedTransport([.ok(#""entries":[]"#)])
    let (client, _) = deviceClient(transport)
    _ = try await client.list(folder: SNFileID(rawValue: 900_000_000_000_000_005))
    let body = String(decoding: transport.calls[0].httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains(#""id":900000000000000005"#))
}

@Test("On the official cloud a listed entry names its folder, and the path is worked out")
func readsTheOfficialListingShape() async throws {
    // A recursive listing returns `path_display`
    // is the folder the entry is in, with a leading slash, and empty at the top;
    // no `parent_path`; folders with an empty hash and a zero size.
    let transport = ScriptedTransport([
        .ok(
            #""equipmentNo":"MACOS-x","entries":["#
                + #"{"tag":"folder","id":"1","name":"NOTE","path_display":"","content_hash":"","size":0,"#
                + #""lastUpdateTime":946687000000,"_downloadable":true},"#
                + #"{"tag":"folder","id":"2","name":"Note","path_display":"/NOTE","content_hash":"","size":0,"#
                + #""lastUpdateTime":946687000000,"_downloadable":true},"#
                + #"{"tag":"file","id":"3","name":"Sample.note","path_display":"/NOTE/Note","content_hash":"e5bd398036d165221d8bf399657498cc","#
                + #""size":8192,"lastUpdateTime":946688000000,"_downloadable":true}]"#
        ),
    ])
    let (client, _) = deviceClient(transport)
    let entries = try await client.list(path: "/", recursive: true)

    #expect(entries.map(\.path) == ["NOTE", "NOTE/Note", "NOTE/Note/Sample.note"])
    #expect(entries.map(\.parentPath) == ["", "NOTE", "NOTE/Note"])
    #expect(entries[2].pathDisplay == "/NOTE/Note")
    #expect(entries[0].contentHash == nil)
}

@Test("A listing of a subfolder names the folder without a slash, and the path is still worked out")
func readsTheSubfolderListingShape() throws {
    let json = #"{"tag":"file","id":"5","name":"scan.pdf","path_display":"INBOX","content_hash":"aa","size":1}"#
    let entry = try JSONDecoder().decode(SNDeviceEntry.self, from: Data(json.utf8))
    #expect(entry.path == "INBOX/scan.pdf")
    #expect(entry.parentPath == "INBOX")
}

@Test("A download link's entry names its whole path")
func readsTheDownloadShape() throws {
    let json = #"{"id":"3","name":"Sample.note","path_display":"NOTE/Note/Sample.note","content_hash":"aa","size":1}"#
    let entry = try JSONDecoder().decode(SNDeviceEntry.self, from: Data(json.utf8))
    #expect(entry.path == "NOTE/Note/Sample.note")
    #expect(entry.parentPath == "NOTE/Note")
}

// MARK: - Uploads the official app's way

private let s3Object = "https://uk-ratta-cloud.s3.eu-west-2.amazonaws.com/fd2ea322-MAC.zip"

private func applyReply(apiServer: String, signed: Bool = true) -> ScriptedTransport.Reply {
    let signature = signed ? #""s3Authorization":"AWS4-HMAC-SHA256 apply","xamzDate":"20261003T000000Z","# : ""
    return .ok(#""equipmentNo":"x",\#(signature)"url":"\#(s3Object)","fileServer":"3","apiServer":"\#(apiServer)""#)
}

private func signature(_ name: String) -> ScriptedTransport.Reply {
    .ok(#""s3Authorization":"AWS4-HMAC-SHA256 \#(name)","xamzDate":"20261003T00000\#(name.count)Z""#)
}

@Test("A file up to eight mebibytes goes to S3 in one PUT signed by upload/apply")
func uploadsASmallFileInOnePut() async throws {
    let transport = ScriptedTransport([
        applyReply(apiServer: "1"),
        .init(body: ""),
        .ok(#""id":"9","name":"a.zip","path_display":"EXPORT/a.zip","size":15,"content_hash":"5b5778d47e5d7cc586801850e65f0d0b""#),
    ])
    let (client, _) = deviceClient(transport)
    _ = try await client.upload(Data("hello supernote".utf8), toPath: "/EXPORT/a.zip")

    #expect(transport.calls.map(\.url?.path) == ["/api/file/3/files/upload/apply", "/fd2ea322-MAC.zip", "/api/file/2/files/upload/finish"])
    let put = transport.calls[1]
    #expect(put.httpMethod == "PUT")
    #expect(put.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 apply")
    #expect(put.value(forHTTPHeaderField: "x-access-token") == nil)
    #expect(put.value(forHTTPHeaderField: "channel") == nil)
    #expect(transport.calls[2].jsonBody["innerName"] as? String == "fd2ea322-MAC.zip")
}

@Test("A larger file goes to S3 in parts, every request signed by file/s3/auth")
func uploadsALargeFileInParts() async throws {
    let size = Int(Transfers.chunkSize) + 10
    var part1 = ScriptedTransport.Reply(body: "")
    part1.headers["ETag"] = "\"etag-1\""
    var part2 = ScriptedTransport.Reply(body: "")
    part2.headers["ETag"] = "\"etag-2\""
    let xml = ["Content-Type": "application/xml"]
    let transport = ScriptedTransport([
        applyReply(apiServer: "1"),
        signature("init"),
        .init(body: "<InitiateMultipartUploadResult><UploadId>up-1</UploadId></InitiateMultipartUploadResult>", headers: xml),
        signature("p1"),
        part1,
        signature("p2"),
        part2,
        signature("done"),
        .init(body: "<CompleteMultipartUploadResult><Key>fd2ea322-MAC.zip</Key></CompleteMultipartUploadResult>", headers: xml),
        .ok(#""id":"9","name":"big.zip","path_display":"EXPORT/big.zip","size":\#(size),"content_hash":"aa""#),
    ])
    let (client, _) = deviceClient(transport)
    let entry = try await client.upload(Data(repeating: 1, count: size), toPath: "/EXPORT/big.zip")
    #expect(entry.id == SNFileID(rawValue: 9))

    let calls = transport.calls
    #expect(calls.map(\.url?.path) == [
        "/api/file/3/files/upload/apply",
        "/api/file/s3/auth", "/fd2ea322-MAC.zip",
        "/api/file/s3/auth", "/fd2ea322-MAC.zip",
        "/api/file/s3/auth", "/fd2ea322-MAC.zip",
        "/api/file/s3/auth", "/fd2ea322-MAC.zip",
        "/api/file/2/files/upload/finish",
    ])

    // Initiate: signed for POST ?uploads, with no body.
    let initiate = calls[1].jsonBody
    #expect(initiate["method"] as? String == "POST")
    #expect(initiate["params"] as? [String: String] == ["uploads": ""])
    #expect(initiate["uri"] as? String == "fd2ea322-MAC.zip")
    #expect(initiate["fileServer"] as? String == "3")
    #expect(initiate["awsHeaders"] as? [String: String] == [:])
    #expect(calls[1].value(forHTTPHeaderField: "channel") != nil, "s3/auth is a call of a sync to the app")
    #expect(calls[2].url?.query == "uploads")
    #expect(calls[2].httpMethod == "POST")
    #expect(calls[2].value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 init")
    #expect(calls[2].value(forHTTPHeaderField: "x-amz-content-sha256") == "UNSIGNED-PAYLOAD")

    // Parts: PUT ?partNumber&uploadId, each signed for itself.
    #expect(calls[3].jsonBody["params"] as? [String: String] == ["partNumber": "1", "uploadId": "up-1"])
    #expect(calls[4].httpMethod == "PUT")
    #expect(calls[4].url?.query == "partNumber=1&uploadId=up-1")
    #expect(calls[4].httpBody?.count == Int(Transfers.chunkSize))
    #expect(calls[6].httpBody?.count == 10)

    // Complete: the ETags as S3 gave them, in bare XML, and the body signed too.
    let expected = #"<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"etag-1"</ETag></Part>"#
        + #"<Part><PartNumber>2</PartNumber><ETag>"etag-2"</ETag></Part></CompleteMultipartUpload>"#
    #expect(calls[7].jsonBody["params"] as? [String: String] == ["uploadId": "up-1"])
    #expect(calls[7].jsonBody["data"] as? String == expected)
    #expect(calls[8].url?.query == "uploadId=up-1")
    #expect(String(decoding: calls[8].httpBody ?? Data(), as: UTF8.self) == expected)

    // No credential to the account ever goes to S3.
    for call in calls where call.url?.host()?.hasSuffix("amazonaws.com") == true {
        #expect(call.value(forHTTPHeaderField: "x-access-token") == nil)
        #expect(call.value(forHTTPHeaderField: "channel") == nil)
    }
    #expect(calls[9].jsonBody["innerName"] as? String == "fd2ea322-MAC.zip")
}

@Test("A completion S3 answers 200 with an error inside is a failure")
func refusesAFailedCompletion() async throws {
    let size = Int(Transfers.chunkSize) + 1
    var part = ScriptedTransport.Reply(body: "")
    part.headers["ETag"] = "\"e\""
    let xml = ["Content-Type": "application/xml"]
    let transport = ScriptedTransport([
        applyReply(apiServer: "1"),
        signature("init"),
        .init(body: "<InitiateMultipartUploadResult><UploadId>u</UploadId></InitiateMultipartUploadResult>", headers: xml),
        signature("p1"), part, signature("p2"), part, signature("done"),
        .init(body: "<Error><Code>InternalError</Code><Message>try again</Message></Error>", headers: xml),
    ])
    let (client, _) = deviceClient(transport)
    await #expect(throws: SNError.rejected(code: "InternalError", message: "try again")) {
        _ = try await client.upload(Data(repeating: 1, count: size), toPath: "/EXPORT/big.zip")
    }
    #expect(!transport.calls.contains { $0.url?.path == "/api/file/2/files/upload/finish" }, "a failed upload was finished")
}

@Test("An upload the service routes to Aliyun OSS is refused before any byte goes")
func refusesAliyun() async throws {
    let transport = ScriptedTransport([applyReply(apiServer: "0")])
    let (client, _) = deviceClient(transport)
    await #expect(throws: SNError.rejected(code: "OSS", message: "uploads to Aliyun OSS are not supported")) {
        _ = try await client.upload(Data("x".utf8), toPath: "/EXPORT/a.txt")
    }
    #expect(transport.calls.count == 1)
}

@Test("A private cloud's device download link to its own storage is moved onto the configured host")
func movesADeviceDownloadOntoTheConfiguredHost() async throws {
    let transport = ScriptedTransport([
        .ok(#""url":"http://172.17.0.2:19071/api/oss/download?path=x&signature=s","content_hash":null,"size":5"#),
        .init(body: "hello", headers: ["Content-Type": "application/octet-stream"]),
    ])
    let (client, _) = deviceClient(transport, endpoints: .privateCloud(URL.constant("http://nas.local:8080")))

    let file = try await client.download(SNFileID(rawValue: 1))
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(transport.calls.last?.url?.absoluteString == "http://nas.local:8080/api/oss/download?path=x&signature=s")
}
