// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Testing

private func entryJSON(_ id: Int, _ name: String, folder: Bool = false) -> String {
    #"{"id":"\#(id)","directoryId":"0","fileName":"\#(name)","isFolder":"\#(folder ? "Y" : "N")","size":10,"md5":"aa"}"#
}

// MARK: - Listing

@Test("A listing is read page by page until the total is reached")
func listsEveryPage() async throws {
    let first = (1...100).map { entryJSON($0, "f\($0)") }.joined(separator: ",")
    let transport = ScriptedTransport([
        .ok(#""total":101,"pages":2,"userFileVOList":[\#(first)]"#),
        .ok(#""total":101,"pages":2,"userFileVOList":[\#(entryJSON(101, "last"))]"#),
    ])
    let (client, _, _) = loggedInClient(transport)

    let entries = try await client.list(.root, order: .time, ascending: false)

    #expect(entries.count == 101)
    #expect(entries.last?.name == "last")
    let bodies = transport.calls.map(\.jsonBody)
    #expect(bodies.map { $0["pageNo"] as? Int } == [1, 2])
    #expect(bodies.first?["directoryId"] as? String == "0")
    #expect(bodies.first?["order"] as? String == "time")
    #expect(bodies.first?["sequence"] as? String == "desc")
    #expect(transport.calls.first?.value(forHTTPHeaderField: "x-access-token") == liveToken)
}

@Test("An empty folder is one request")
func listsAnEmptyFolder() async throws {
    let transport = ScriptedTransport([.ok(#""total":0,"pages":0,"userFileVOList":[]"#)])
    let (client, _, _) = loggedInClient(transport)
    #expect(try await client.list(SNFileID(rawValue: 7)).isEmpty)
    #expect(transport.calls.count == 1)
}

@Test("A refused token is dropped, and the next call does not send it")
func dropsARefusedToken() async throws {
    let transport = ScriptedTransport([.refused("E0712", "not logged in")])
    let (client, session, secrets) = loggedInClient(transport)

    await #expect(throws: SNError.sessionExpired) { _ = try await client.list() }
    #expect(try secrets.secret(.accessToken) == nil)
    #expect(try await !session.isLoggedIn)
    await #expect(throws: SNError.notLoggedIn) { _ = try await client.capacity() }
    #expect(transport.calls.count == 1, "a call went out with no token to send")
}

@Test("A 403 is met with a fresh XSRF token, once")
func refreshesAStaleXSRFToken() async throws {
    let transport = ScriptedTransport(
        [.init(status: 403), .ok(#""usedCapacity":"5","totalCapacity":10"#)],
        xsrf: ["stale", "fresh"]
    )
    let (client, _, _) = loggedInClient(transport)

    #expect(try await client.capacity() == SNCapacity(used: 5, total: 10))
    #expect(transport.handshakes == 2)
    #expect(transport.calls.map { $0.value(forHTTPHeaderField: "X-XSRF-TOKEN") } == ["stale", "fresh"])

    // A second 403 is about something else, and is reported.
    let refusing = ScriptedTransport([.init(status: 403), .init(status: 403)])
    let (other, _, _) = loggedInClient(refusing)
    await #expect(throws: SNError.http(status: 403, path: "/api/file/capacity/query")) { _ = try await other.capacity() }
    #expect(refusing.calls.count == 2)
}

@Test("A read that met a 5xx is asked again; a change is not")
func retriesReadsButNotChanges() async throws {
    let reading = ScriptedTransport([.init(status: 503), .ok(#""usedCapacity":1,"totalCapacity":2"#)])
    let (client, _, _) = loggedInClient(reading)
    _ = try await client.capacity()
    #expect(reading.calls.count == 2)

    // The copy may have been made; the answer is what was lost.
    let changing = ScriptedTransport([.init(status: 503), .ok()])
    let (other, _, _) = loggedInClient(changing)
    await #expect(throws: SNError.http(status: 503, path: "/api/file/copy")) {
        try await other.copy([SNFileID(rawValue: 1)], from: .root, to: SNFileID(rawValue: 2))
    }
    #expect(changing.calls.count == 1)
}

@Test("A 429 is waited out even on a change: it says nothing was done")
func retriesARateLimitedChange() async throws {
    let transport = ScriptedTransport([.init(status: 429, headers: ["Retry-After": "2"]), .ok()])
    let sleeper = RecordingSleeper()
    let (client, _, _) = loggedInClient(transport, sleeper: sleeper)
    try await client.rename(SNFileID(rawValue: 9), to: "New")
    #expect(sleeper.delays == [.seconds(2)])
    #expect(transport.calls.last?.jsonBody["newName"] as? String == "New")
    #expect(transport.calls.last?.jsonBody["id"] as? String == "9")
}

@Test("A new folder is found again by name, since the service does not name it")
func findsANewFolder() async throws {
    let transport = ScriptedTransport([
        .ok(),
        .ok(#""total":2,"userFileVOList":[\#(entryJSON(5, "Inbox", folder: true)),\#(entryJSON(6, "Projects", folder: true))]"#),
    ])
    let (client, _, _) = loggedInClient(transport)
    let folder = try await client.createFolder(named: "Projects")
    #expect(folder.id == SNFileID(rawValue: 6))
    #expect(transport.calls.first?.url?.path == "/api/file/folder/add")
}

@Test("Moving names the source, the destination and every entry")
func movesEntries() async throws {
    let transport = ScriptedTransport([.ok()])
    let (client, _, _) = loggedInClient(transport)
    try await client.move([SNFileID(rawValue: 1), SNFileID(rawValue: 2)], from: .root, to: SNFileID(rawValue: 3))
    let body = transport.calls[0].jsonBody
    #expect(body["idList"] as? [String] == ["1", "2"])
    #expect(body["directoryId"] as? String == "0")
    #expect(body["goDirectoryId"] as? String == "3")
}

@Test("Nothing to move is no request at all")
func skipsAnEmptyChange() async throws {
    let transport = ScriptedTransport([])
    let (client, _, _) = loggedInClient(transport)
    try await client.delete([], from: .root)
    #expect(transport.requests.isEmpty)
}

@Test("A location is split into names and identifiers")
func readsALocation() async throws {
    let transport = ScriptedTransport([.ok(#""path":"Note/Meetings/","idPath":"12/34/""#)])
    let (client, _, _) = loggedInClient(transport)
    let location = try await client.location(of: SNFileID(rawValue: 34))
    #expect(location.names == ["Note", "Meetings"])
    #expect(location.ids == [SNFileID(rawValue: 12), SNFileID(rawValue: 34)])
}

// MARK: - Downloading

@Test("A download comes from the signed URL with no token on it, and is checked")
func downloadsAndVerifies() async throws {
    let transport = ScriptedTransport([
        .ok(#""url":"https://storage.example.com/obj?X-Amz-Signature=s","md5":"5b5778d47e5d7cc586801850e65f0d0b""#),
        .init(body: "hello supernote", headers: ["Content-Type": "application/octet-stream"]),
    ])
    let (client, _, _) = loggedInClient(transport)

    let file = try await client.download(SNFileID(rawValue: 42))
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(try Data(contentsOf: file) == Data("hello supernote".utf8))
    let storage = try #require(transport.calls.last)
    #expect(storage.url?.host() == "storage.example.com")
    #expect(storage.value(forHTTPHeaderField: "x-access-token") == nil)
    #expect(storage.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(transport.calls.first?.jsonBody["id"] as? String == "42")
}

@Test("Bytes that disagree with the declared MD5 never reach the caller")
func refusesAMismatchedDownload() async throws {
    // What an expired signature has been seen to answer: 200, and XML.
    let transport = ScriptedTransport([
        .ok(#""url":"https://storage.example.com/obj","md5":"5b5778d47e5d7cc586801850e65f0d0b""#),
        .init(body: "<Error><Code>AccessDenied</Code></Error>", headers: ["Content-Type": "application/xml"]),
    ])
    let (client, _, _) = loggedInClient(transport)
    await #expect {
        _ = try await client.download(SNFileID(rawValue: 42))
    } throws: { error in
        guard case SNError.checksumMismatch(let expected, _) = error else { return false }
        return expected == "5b5778d47e5d7cc586801850e65f0d0b"
    }
}

@Test("A refusal from storage is not taken for an ended session")
func keepsTheSessionWhenStorageRefuses() async throws {
    let transport = ScriptedTransport([
        .ok(#""url":"https://storage.example.com/obj","md5":"""#),
        .init(status: 401),
    ])
    let (client, session, _) = loggedInClient(transport)
    await #expect(throws: SNError.http(status: 401, path: "/obj")) { _ = try await client.download(SNFileID(rawValue: 1)) }
    #expect(try await session.isLoggedIn)
}

// MARK: - Uploading

@Test("On the official cloud the bytes go up as one signed PUT")
func uploadsToS3() async throws {
    let transport = ScriptedTransport([
        .ok(#""url":"https://bucket.s3.amazonaws.com/user/abc123.pdf","s3Authorization":"AWS4-HMAC-SHA256 sig","xamzDate":"20261003T000000Z""#),
        .init(body: ""),
        .ok(),
    ])
    let (client, _, _) = loggedInClient(transport)

    try await client.upload(Data("hello supernote".utf8), named: "Paper.pdf", to: SNFileID(rawValue: 77))

    let calls = transport.calls
    #expect(calls.map(\.url?.path) == ["/api/file/upload/apply", "/user/abc123.pdf", "/api/file/upload/finish"])
    let apply = calls[0].jsonBody
    #expect(apply["fileName"] as? String == "Paper.pdf")
    #expect(apply["md5"] as? String == "5b5778d47e5d7cc586801850e65f0d0b")
    #expect(apply["size"] as? Int == 15)
    #expect(apply["directoryId"] as? String == "77")

    let put = calls[1]
    #expect(put.httpMethod == "PUT")
    #expect(put.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 sig")
    #expect(put.value(forHTTPHeaderField: "x-amz-date") == "20261003T000000Z")
    #expect(put.value(forHTTPHeaderField: "x-amz-content-sha256") == "UNSIGNED-PAYLOAD")
    #expect(put.value(forHTTPHeaderField: "x-access-token") == nil)
    #expect(put.httpBody == Data("hello supernote".utf8))

    let finish = calls[2].jsonBody
    #expect(finish["innerName"] as? String == "abc123.pdf")
    #expect(finish["fileSize"] as? Int == 15)
    #expect(finish["md5"] as? String == "5b5778d47e5d7cc586801850e65f0d0b")
}

@Test("On a private cloud the bytes go up as a form")
func uploadsAForm() async throws {
    let transport = ScriptedTransport([
        // The server names its internal port; the form goes to the configured one.
        .ok(#""fullUploadUrl":"http://nas.local:8080/api/oss/upload?signature=s&path=p","innerName":"from-apply""#),
        .ok(#""innerName":"stored.note","md5":null"#),
        .ok(),
    ])
    let (client, _, _) = loggedInClient(transport, endpoints: .privateCloud(.constant("http://nas.local:19072")))

    try await client.upload(Data("hello supernote".utf8), named: "My \"Note\".note")

    let form = transport.calls[1]
    #expect(form.httpMethod == "POST")
    #expect(form.url?.path == "/api/oss/upload")
    #expect(form.url?.port == 19072, "the form went to the port the server named, not the configured one")
    #expect(form.url?.query?.contains("signature=s") == true)
    #expect(form.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    // Ratta's server answers its own upload endpoint 401 without the token.
    #expect(form.value(forHTTPHeaderField: "x-access-token") == liveToken)
    let body = String(decoding: form.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains(#"name="file"; filename="My 'Note'.note""#))
    #expect(body.contains("\r\n\r\nhello supernote\r\n--"))
    #expect(transport.calls[2].jsonBody["innerName"] as? String == "stored.note")
}

@Test("A form whose echoed MD5 disagrees is refused before the upload is finished")
func refusesAMismatchedForm() async throws {
    let transport = ScriptedTransport([
        .ok(#""fullUploadUrl":"http://nas.local/api/oss/upload?s=1""#),
        .ok(#""innerName":"x","md5":"0000""#),
    ])
    let (client, _, _) = loggedInClient(transport, endpoints: .privateCloud(.constant("http://nas.local")))
    await #expect(throws: SNError.checksumMismatch(expected: "5b5778d47e5d7cc586801850e65f0d0b", actual: "0000")) {
        try await client.upload(Data("hello supernote".utf8), named: "a.txt")
    }
    #expect(transport.calls.count == 2, "a finish went out for bytes the server disagreed about")
}

@Test("A large file goes to a private cloud in eight-mebibyte parts")
func uploadsInParts() async throws {
    let size = Int(Transfers.chunkSize) + 10
    let data = Data(repeating: 7, count: size)
    let transport = ScriptedTransport([
        .ok(#""fullUploadUrl":"http://nas.local/api/oss/upload?s=1","partUploadUrl":"http://nas.local/api/oss/upload/part?s=1","innerName":"big.bin""#),
        .ok(#""chunkMd5":null"#),
        .ok(#""chunkMd5":null"#),
        .ok(),
    ])
    let (client, _, _) = loggedInClient(transport, endpoints: .privateCloud(.constant("http://nas.local")))

    try await client.upload(data, named: "big.bin")

    let parts = transport.calls.filter { $0.url?.path == "/api/oss/upload/part" }
    #expect(parts.count == 2)
    let query = parts.map { URLComponents(url: $0.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems ?? [] }
    #expect(query.map { $0.first { $0.name == "partNumber" }?.value } == ["1", "2"])
    #expect(query.allSatisfy { $0.first { $0.name == "totalChunks" }?.value == "2" })
    #expect(query.allSatisfy { $0.contains { $0.name == "s" } }, "the signature was dropped from the part URL")
    #expect(transport.calls.last?.jsonBody["innerName"] as? String == "big.bin")
}
