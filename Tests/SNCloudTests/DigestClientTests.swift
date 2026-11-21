// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Testing

// Fingerprint expectations are computed independently with Python hashlib.

private let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

private func digestClient(_ transport: ScriptedTransport) -> SNDigestClient {
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com", .clientID: testClientID])
    let session = SNSession(endpoints: .official, transport: transport, secrets: secrets, sleeper: RecordingSleeper())
    return SNDigestClient(session: session, now: { fixedNow })
}

/// Nineteen digits: what a `Double` would not keep.
private let snowflake: Int64 = 1_000_000_000_000_000_009

private let digestRow = #"""
{"id":1000000000000000009,"fileId":900000000000000005,"name":null,"userId":7,"author":"Column author",
 "uniqueIdentifier":"d-1","parentUniqueIdentifier":"g-1","content":"Sample extract",
 "sourcePath":"/Document/Sample.pdf","dataSource":"pdf","sourceType":1,"isSummaryGroup":"N",
 "tags":"quotes, philosophy","md5Hash":"f33d7355548ab835384f190ba404c955","metadata":"{\"page\":3}",
 "commentStr":"","commentHandwriteName":"c.mark","handwriteInnerName":"abc.mark","handwriteMD5":"ff",
 "creationTime":946685000000,"lastModifiedTime":946685002000,"isDeleted":"N",
 "createTime":"2000-01-01T00:00:00.000+0000","updateTime":"2000-01-01T00:00:00.000+0000"}
"""#

@Test("Digests are read page by page, and their identifiers keep every digit")
func listsDigests() async throws {
    let transport = ScriptedTransport([
        .ok(#""totalRecords":3,"totalPages":2,"currentPage":1,"pageSize":100,"summaryDOList":[\#(digestRow)]"#),
        .ok(#""totalRecords":3,"totalPages":2,"currentPage":2,"pageSize":100,"summaryDOList":[{"id":2,"md5Hash":"x","isDeleted":"Y"}]"#),
    ])
    let digests = try await digestClient(transport).digests(in: "g-1")

    let first = try #require(transport.calls.first)
    #expect(first.url?.absoluteString == "https://viewer.supernote.com/api/file/query/summary")
    #expect(first.jsonBody["page"] as? Int == 1)
    #expect(first.jsonBody["size"] as? Int == 100)
    #expect(first.jsonBody["parentUniqueIdentifier"] as? String == "g-1")
    #expect(transport.calls[1].jsonBody["page"] as? Int == 2)

    #expect(digests.count == 1)
    let digest = try #require(digests.first)
    #expect(digest.id.rawValue == snowflake)
    #expect(digest.fileID == SNFileID(rawValue: 900_000_000_000_000_005))
    #expect(digest.groupIdentifier == "g-1")
    #expect(digest.content == "Sample extract")
    #expect(digest.tags == ["quotes", "philosophy"])
    #expect(digest.comment == nil)
    #expect(digest.handwritingName == "c.mark")
    #expect(digest.handwritingMD5 == "ff")
    #expect(digest.created == Date(timeIntervalSince1970: 946_685_000))
    #expect(digest.metadata == #"{"page":3}"#)
}

@Test("A new digest is named in its metadata and fingerprinted as the tablet does it")
func createsADigest() async throws {
    let transport = ScriptedTransport([.ok(#""id":1000000000000000009"#)])
    let draft = SNDigestDraft(
        content: "Sample extract",
        groupIdentifier: "g-1",
        fileID: SNFileID(rawValue: 900_000_000_000_000_005),
        tags: ["quotes", "philosophy"]
    )

    let id = try await digestClient(transport).create(draft, uniqueIdentifier: "d-1")

    #expect(id.rawValue == snowflake)
    let call = try #require(transport.calls.first)
    #expect(call.url?.path == "/api/file/add/summary")
    let body = call.jsonBody
    // The tablet leaves the column empty and names the digest in the metadata.
    #expect(body["uniqueIdentifier"] == nil)
    #expect(body["metadata"] as? String == #"{"unique_identifier":"d-1"}"#)
    #expect(body["parentUniqueIdentifier"] as? String == "g-1")
    #expect(body["fileId"] as? Int64 == 900_000_000_000_000_005)
    #expect(body["tags"] as? String == "quotes,philosophy")
    // What the tablet sends for a typed digest, and its fingerprint over them:
    // content + group + source type + source path + metadata + comments.
    #expect(body["sourceType"] as? Int == 4)
    #expect((body["sourcePath"] as? String)?.isEmpty == true)
    #expect((body["commentStr"] as? String)?.isEmpty == true)
    #expect((body["commentHandwriteName"] as? String)?.isEmpty == true)
    #expect(body["md5Hash"] as? String == "0d08691b202f3a948b077280a70203f3")
    #expect(body["creationTime"] as? Int64 == 1_780_000_000_000)
    #expect(body["lastModifiedTime"] as? Int64 == 1_780_000_000_000)
    #expect(body["id"] == nil)
}

@Test("An update of a field outside the fingerprint sends only that field; a delete names the digest in a JSON body")
func updatesAndDeletesADigest() async throws {
    let transport = ScriptedTransport([.ok(), .ok()])
    let client = digestClient(transport)
    let id = SNDigestID(rawValue: snowflake)

    try await client.update(id, with: SNDigestDraft(dataSource: "pdf"))
    try await client.delete(id)

    let update = transport.calls[0]
    #expect(update.httpMethod == "PUT")
    #expect(update.url?.path == "/api/file/update/summary")
    #expect(Set(update.jsonBody.keys) == ["id", "dataSource", "lastModifiedTime"])
    #expect(update.jsonBody["id"] as? Int64 == snowflake)

    let delete = transport.calls[1]
    #expect(delete.httpMethod == "DELETE")
    #expect(delete.url?.path == "/api/file/delete/summary")
    #expect(delete.jsonBody["id"] as? Int64 == snowflake)
}

private let groupRow = #"""
{"id":5,"uniqueIdentifier":"g-1","name":"Reading","description":"","md5Hash":"26fccddf2f94b1685b184267996e10f8",
 "isSummaryGroup":"Y","creationTime":946685000000,"lastModifiedTime":0,"isDeleted":"N"}
"""#

@Test("Groups are made with the tablet's fingerprint: identifier and name")
func readsAndMakesGroups() async throws {
    let transport = ScriptedTransport([
        .ok(#""totalPages":1,"currentPage":1,"summaryDOList":[\#(groupRow)]"#),
        .ok(#""id":6"#),
        .ok(),
    ])
    let client = digestClient(transport)

    let groups = try await client.groups()
    #expect(transport.calls[0].url?.path == "/api/file/query/summary/group")
    #expect(groups == [SNDigestGroup(
        id: SNDigestID(rawValue: 5),
        uniqueIdentifier: "g-1",
        name: "Reading",
        md5Hash: "26fccddf2f94b1685b184267996e10f8",
        created: Date(timeIntervalSince1970: 946_685_000)
    )])

    let made = try await client.createGroup(named: "Reading", uniqueIdentifier: "g-2")
    #expect(made == SNDigestID(rawValue: 6))
    #expect(transport.calls[1].jsonBody["md5Hash"] as? String == "5fda197f6aeb44b6d49bb7e5e88917ab")
    #expect(transport.calls[1].jsonBody["uniqueIdentifier"] as? String == "g-2")

    try await client.deleteGroup(made)
    #expect(transport.calls[2].httpMethod == "DELETE")
    #expect(transport.calls[2].jsonBody["id"] as? Int64 == 6)
}

private let fingerprintRow = #"""
{"id":9,"userId":7,"md5Hash":"aa","handwriteMd5":"bb","commentHandwriteName":"c.mark",
 "lastModifiedTime":946685002000,"metadataMap":{"author":"Column author"}}
"""#

@Test("Fingerprints read the hash answer's own spellings")
func readsFingerprints() async throws {
    let transport = ScriptedTransport([
        .ok(#""totalPages":1,"summaryInfoVOList":[\#(fingerprintRow)]"#),
    ])
    let prints = try await digestClient(transport).fingerprints()
    #expect(transport.calls[0].url?.path == "/api/file/query/summary/hash")
    #expect(transport.calls[0].jsonBody["parentUniqueIdentifier"] == nil)
    #expect(prints == [SNDigestFingerprint(
        id: SNDigestID(rawValue: 9),
        md5Hash: "aa",
        handwritingMD5: "bb",
        handwritingName: "c.mark",
        modified: Date(timeIntervalSince1970: 946_685_002),
        author: "Column author"
    )])
}

@Test("Tags are read with a GET, and a taken name is alreadyExists")
func readsAndMakesTags() async throws {
    let transport = ScriptedTransport([
        .ok(#""summaryTagDOList":[{"id":3,"name":"quotes","userId":7,"uniqueIdentifier":null,"createdAt":"2000-01-01T00:00:00.000+0000"}]"#),
        .refused("E0335", "The tag name already exists."),
        .refused("E0336", "The tag does not exist."),
    ])
    let client = digestClient(transport)

    #expect(try await client.tags() == [SNDigestTag(id: SNDigestID(rawValue: 3), name: "quotes")])
    #expect(transport.calls[0].httpMethod == "GET")
    #expect(transport.calls[0].httpBody == nil)
    #expect(transport.calls[0].url?.path == "/api/file/query/summary/tag")

    await #expect(throws: SNError.alreadyExists) { try await client.createTag(named: "quotes") }
    await #expect(throws: SNError.notFound(code: "E0336")) { try await client.renameTag(SNDigestID(rawValue: 4), to: "x") }
}

@Test("Without a page count, a short page is the last one")
func stopsOnAShortPageWithoutACount() async throws {
    let transport = ScriptedTransport([.ok(#""summaryDOList":[\#(digestRow)]"#)])
    let digests = try await digestClient(transport).digests()
    #expect(digests.count == 1)
    #expect(transport.calls.count == 1)
    #expect(transport.calls[0].jsonBody["parentUniqueIdentifier"] == nil)
}

@Test("A digest seen on two pages is listed once")
func dropsADigestSeenTwice() async throws {
    let transport = ScriptedTransport([
        .ok(#""totalPages":2,"summaryDOList":[\#(digestRow)]"#),
        .ok(#""totalPages":2,"summaryDOList":[\#(digestRow)]"#),
    ])
    #expect(try await digestClient(transport).digests().count == 1)
}

@Test("A tag with a comma is refused before anything is sent: it would come back as two")
func refusesATagWithAComma() async throws {
    let transport = ScriptedTransport([])
    let client = digestClient(transport)
    await #expect(throws: SNError.self) { try await client.create(SNDigestDraft(content: "x", tags: ["a,b"])) }
    await #expect(throws: SNError.self) { try await client.update(SNDigestID(rawValue: 1), with: SNDigestDraft(tags: ["a,b"])) }
    #expect(transport.calls.isEmpty)
}

@Test("Digests by identifier go as numbers; a group update looks the group up for its fingerprint")
func readsByIdentifierAndUpdatesAGroup() async throws {
    let transport = ScriptedTransport([
        .ok(#""summaryDOList":[\#(digestRow)]"#),
        .ok(#""totalPages":1,"summaryDOList":[\#(groupRow)]"#),
        .ok(),
        .refused("E0338", "The unique identifier already exists."),
    ])
    let client = digestClient(transport)

    let found = try await client.digests([SNDigestID(rawValue: snowflake)])
    #expect(found.map(\.id.rawValue) == [snowflake])
    #expect(transport.calls[0].url?.path == "/api/file/query/summary/id")
    #expect(transport.calls[0].jsonBody["ids"] as? [Int64] == [snowflake])

    try await client.updateGroup(SNDigestID(rawValue: 5), name: "Reading")
    #expect(transport.calls[1].url?.path == "/api/file/query/summary/group")
    #expect(transport.calls[2].httpMethod == "PUT")
    #expect(transport.calls[2].url?.path == "/api/file/update/summary/group")
    #expect(transport.calls[2].jsonBody["md5Hash"] as? String == "f95a59c592ee87c6bbc223c937caffd2")
    #expect(transport.calls[2].jsonBody["description"] == nil)

    await #expect(throws: SNError.alreadyExists) { try await client.createGroup(named: "Reading", uniqueIdentifier: "g-1") }
}

// Synthetic records use the group column and the digest metadata for identifiers.
private let sampleGroup = #"""
{"id":900000000000000001,"name":"Sample group","uniqueIdentifier":"aff7a819c30c1f2a1b0866d800f61ec3","isSummaryGroup":"Y",
 "description":"","md5Hash":"128425d56c2a637df79166e50323c74f","creationTime":946684801123,"lastModifiedTime":946684801123,
 "isDeleted":"N","createTime":946684802000}
"""#

private let sampleDigest = #"""
{"id":900000000000000003,"fileId":null,"uniqueIdentifier":null,"parentUniqueIdentifier":"aff7a819c30c1f2a1b0866d800f61ec3",
 "content":"Fixture paragraph","sourcePath":"","sourceType":4,"isSummaryGroup":"N","tags":null,"md5Hash":"cdd77a73c6cc7d8c6ca7dd049d4a7750",
 "metadata":"{\"unique_identifier\":\"3a4461619c6fc2e7c5ba8efc4167687d\"}","commentStr":"","commentHandwriteName":"",
 "creationTime":946684811123,"lastModifiedTime":946684811123,"isDeleted":"N","createTime":946684812000}
"""#

@Test("Group and digest fingerprints match independently calculated values")
func matchesDigestFingerprints() throws {
    let group = try JSONDecoder().decode(SNDigestGroup.self, from: Data(sampleGroup.utf8))
    let digest = try JSONDecoder().decode(SNDigest.self, from: Data(sampleDigest.utf8))

    #expect(digest.uniqueIdentifier == "3a4461619c6fc2e7c5ba8efc4167687d")
    #expect(digest.groupIdentifier == group.uniqueIdentifier)
    #expect(digest.sourceType == 4)
    #expect(DigestFingerprint.group(uniqueIdentifier: group.uniqueIdentifier, name: group.name)
        == group.md5Hash)
    #expect(DigestFingerprint.digest(.init(
        content: digest.content,
        group: digest.groupIdentifier,
        sourceType: digest.sourceType,
        sourcePath: digest.sourcePath,
        metadata: digest.metadata,
        comment: digest.comment,
        handwritingName: digest.handwritingName
    )) == digest.md5Hash)
    // And the tablet's form of an identifier: 32 lowercase hex digits.
    let made = SNDigestClient.newIdentifier()
    #expect(made.count == 32 && made.allSatisfy { $0.isHexDigit && !$0.isUppercase })
}

@Test("A content change is fingerprinted with the fields the digest already has")
func refingerprintsAChangedDigest() async throws {
    let transport = ScriptedTransport([.ok(#""summaryDOList":[\#(sampleDigest)]"#), .ok()])
    try await digestClient(transport).update(SNDigestID(rawValue: 900_000_000_000_000_003), with: SNDigestDraft(content: "Edited paragraph"))
    #expect(transport.calls[0].url?.path == "/api/file/query/summary/id")
    #expect(transport.calls[1].jsonBody["md5Hash"] as? String == "4d7b58518686ec5ecb4e4512d4e4d04c")
}

@Test("A digest from a book, with both comments: the source path, the typed comment and the handwritten one's file are summed too")
func fingerprintsABookDigest() {
    // The shape of a tablet's digest from an EPUB — no group, `sourceType` 1,
    // location metadata, a handwritten comment — with neutral text; the hash
    // is Python's `hashlib` over the same seven fields.
    let metadata = #"{"source_size":4096,"unique_identifier":"086106ad0f2910b72126607dcc1f710c"}"#
    let sum = DigestFingerprint.digest(.init(
        content: "Example excerpt",
        group: "",
        sourceType: 1,
        sourcePath: "INBOX/example.epub",
        metadata: metadata,
        comment: "Margin note",
        handwritingName: "6775be63719e0d219a100177bbedde3e.mark"
    ))
    #expect(sum == "2f4170bb32fd051bc7cb376f921d9add")
}

@Test("The author lives in the metadata, as the tablet keeps it: written there, read from there, summed with it")
func keepsTheAuthorInTheMetadata() async throws {
    let transport = ScriptedTransport([.ok(#""id":7"#), .ok(#""summaryDOList":[\#(sampleDigest)]"#), .ok()])
    let client = digestClient(transport)

    try await client.create(SNDigestDraft(content: "x", author: "Fixture author"), uniqueIdentifier: "d-2")
    let made = transport.calls[0].jsonBody
    #expect(made["author"] == nil)
    #expect(made["metadata"] as? String == #"{"author":"Fixture author","unique_identifier":"d-2"}"#)

    try await client.update(SNDigestID(rawValue: 900_000_000_000_000_003), with: SNDigestDraft(author: "Fixture author"))
    #expect(transport.calls[1].url?.path == "/api/file/query/summary/id")
    let changed = transport.calls[2].jsonBody
    let metadata = #"{"author":"Fixture author","unique_identifier":"3a4461619c6fc2e7c5ba8efc4167687d"}"#
    #expect(changed["author"] == nil)
    #expect(changed["metadata"] as? String == metadata)
    #expect(changed["md5Hash"] as? String == "d79ce63d7bde58ef0f0d3222d4968e3a")

    let row = sampleDigest.replacingOccurrences(of: #"\"}","commentStr"#, with: #"\",\"author\":\"Fixture author\"}","commentStr"#)
    #expect(try JSONDecoder().decode(SNDigest.self, from: Data(row.utf8)).author == "Fixture author")
}

@Test("The metadata's author outranks an older column, and an empty one clears it")
func prefersTheMetadataAuthor() throws {
    func author(column: String, metadata: String) throws -> String? {
        let row = #"{"id":1,"author":"\#(column)","metadata":"\#(metadata)"}"#
        return try JSONDecoder().decode(SNDigest.self, from: Data(row.utf8)).author
    }
    #expect(try author(column: "Column author", metadata: #"{\"author\":\"Fixture author\"}"#) == "Fixture author")
    #expect(try author(column: "Column author", metadata: #"{\"author\":\"\"}"#) == nil)
    #expect(try author(column: "Column author", metadata: #"{\"unique_identifier\":\"x\"}"#) == "Column author")
}

@Test("A second write to one digest on the same session is refused while the first runs")
func refusesOverlappingDigestWrites() async throws {
    let gate = HeldTransport(ScriptedTransport([.ok(), .ok()]), holding: "/api/file/update/summary")
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com", .clientID: testClientID])
    let session = SNSession(endpoints: .official, transport: gate, secrets: secrets, sleeper: RecordingSleeper())
    let first = SNDigestClient(session: session)
    let second = SNDigestClient(session: session)
    let id = SNDigestID(rawValue: 9)

    let running = Task { try await first.update(id, with: SNDigestDraft(dataSource: "pdf")) }
    await gate.waitForHeldRequest()
    await #expect(throws: SNError.rejected(code: SNDigestClient.busy, message: "another write to digest 9 is running on this session")) {
        try await second.delete(id)
    }
    gate.letThrough()
    try await running.value
    // Once it is done, the digest is free again.
    try await second.delete(id)
}

@Test("A handwritten comment goes up as the service's apply says — one signed S3 PUT — and comes back named by the service")
func uploadsAHandwrittenComment() async throws {
    let transport = ScriptedTransport([
        .ok(#"""
        "s3Url":"https://uk-ratta-cloud.s3.eu-west-2.amazonaws.com/fixture-MAC.mark","s3Authorization":"AWS4-HMAC-SHA256 sig",
        "xamzDate":"20000101T000000Z","innerName":"fixture-MAC.mark","fileServer":"3","apiServer":"1","url":null
        """#),
        .init(body: ""),
    ])
    let file = try ScratchFile.write(Data("handwritten strokes".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    let handwriting = try await digestClient(transport).uploadHandwriting(contentsOf: file, named: "abc.mark")

    #expect(handwriting == SNDigestHandwriting(name: "abc.mark", innerName: "fixture-MAC.mark", md5: "6a9cb52b577a7354e41c42757c777289"))
    let apply = transport.calls[0]
    #expect(apply.url?.absoluteString == "https://viewer.supernote.com/api/file/upload/apply/summary")
    #expect(apply.jsonBody["fileName"] as? String == "abc.mark")
    #expect(apply.jsonBody["equipmentNo"] as? String == testEquipmentNo)
    #expect(apply.value(forHTTPHeaderField: "channel") != nil)
    let put = transport.calls[1]
    #expect(put.httpMethod == "PUT")
    #expect(put.url?.host() == "uk-ratta-cloud.s3.eu-west-2.amazonaws.com")
    #expect(put.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 sig")
    #expect(put.value(forHTTPHeaderField: "x-access-token") == nil)
    // The tablet names these `<32 hex>.mark` when nobody names them.
    #expect(SNDigestClient.newIdentifier().count == 32)
}

@Test("A handwritten comment comes down checked against the digest's MD5; a digest without one asks nothing")
func downloadsAHandwrittenComment() async throws {
    let row = digestRow.replacingOccurrences(of: #""handwriteMD5":"ff""#, with: #""handwriteMD5":"6a9cb52b577a7354e41c42757c777289""#)
    let digest = try JSONDecoder().decode(SNDigest.self, from: Data(row.utf8))
    let transport = ScriptedTransport([
        .ok(#""url":"https://uk-ratta-cloud.s3.eu-west-2.amazonaws.com/abc.mark?X-Amz-Signature=s""#),
        .init(body: "handwritten strokes", headers: ["Content-Type": "application/octet-stream"]),
        .ok(#""url":"https://uk-ratta-cloud.s3.eu-west-2.amazonaws.com/abc.mark?X-Amz-Signature=s""#),
        .init(body: "something else", headers: ["Content-Type": "application/octet-stream"]),
    ])
    let client = digestClient(transport)

    let file = try #require(try await client.handwriting(of: digest))
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try Data(contentsOf: file) == Data("handwritten strokes".utf8))
    #expect(transport.calls[0].url?.path == "/api/file/download/summary")
    #expect(transport.calls[0].jsonBody["id"] as? Int64 == snowflake)

    await #expect(throws: SNError.self) { _ = try await client.handwriting(of: digest) }

    let plain = try JSONDecoder().decode(SNDigest.self, from: Data(sampleDigest.utf8))
    let before = transport.calls.count
    #expect(try await client.handwriting(of: plain) == nil)
    #expect(transport.calls.count == before)
}

@Test("A handwritten comment set on a digest is named in it, and summed into its fingerprint")
func attachesAHandwrittenComment() async throws {
    let transport = ScriptedTransport([.ok(#""summaryDOList":[\#(sampleDigest)]"#), .ok()])
    let handwriting = SNDigestHandwriting(name: "abc.mark", innerName: "fixture-MAC.mark", md5: "6a9cb52b577a7354e41c42757c777289")

    try await digestClient(transport).update(SNDigestID(rawValue: 900_000_000_000_000_003), with: SNDigestDraft(handwriting: handwriting))

    let body = transport.calls[1].jsonBody
    #expect(body["commentHandwriteName"] as? String == "abc.mark")
    #expect(body["handwriteInnerName"] as? String == "fixture-MAC.mark")
    #expect(body["handwriteMD5"] as? String == "6a9cb52b577a7354e41c42757c777289")
    #expect(body["md5Hash"] as? String == "74a030a064e1ea1309015cadd046d723")
}
