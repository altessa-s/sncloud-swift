// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Testing

// MARK: - Digests

// The expected values below were computed with Python's `hashlib`, the way the
// reference clients compute them — not with the code under test.

@Test("The password digest is SHA-256 of the MD5 hex and the salt")
func digestsThePassword() {
    #expect(
        Digests.password("correct horse", salt: "testSalt")
            == "250c1bf6d6911e208059ca108051b4f8946aca59a305752d4ded843743639e98"
    )
}

@Test("A file's MD5 is read in slices and agrees with the MD5 of its bytes")
func hashesAFile() throws {
    let file = try ScratchFile.write(Data("hello supernote".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let (md5, size) = try Digests.md5(ofFile: file)
    #expect(md5 == "5b5778d47e5d7cc586801850e65f0d0b")
    #expect(size == 15)
}

@Test("A token's expiry is read in seconds, and in milliseconds where it is that")
func readsTheExpiry() {
    #expect(AccessTokenClaims.expiry(of: syntheticToken(claims: #"{"exp":4102444800}"#))
        == Date(timeIntervalSince1970: 4_102_444_800))
    #expect(AccessTokenClaims.expiry(of: syntheticToken(claims: #"{"exp":4102444800000}"#))
        == Date(timeIntervalSince1970: 4_102_444_800))
    #expect(AccessTokenClaims.expiry(of: syntheticToken(claims: #"{"userId":"1"}"#)) == nil)
    #expect(AccessTokenClaims.expiry(of: "not-a-jwt") == nil)
}

// MARK: - The service's scalars

@Test("An entry decodes from strings, numbers and Y/N alike")
func decodesAnEntry() throws {
    let json = #"""
    {"id":"900000000000000005","directoryId":0,"fileName":"Sample.note","size":"2048",
     "md5":"ABCDEF","isFolder":"N","createTime":1700000000000,"updateTime":"1700000001000"}
    """#
    let entry = try JSONDecoder().decode(SNEntry.self, from: Data(json.utf8))

    // Eighteen digits, all of them: a decoder that went through Double would
    // name a different file.
    #expect(entry.id.rawValue == 900_000_000_000_000_005)
    #expect(entry.parentID == .root)
    #expect(entry.isFolder == false)
    #expect(entry.size == 2048)
    #expect(entry.md5 == "abcdef")
    #expect(entry.created == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(entry.modified == Date(timeIntervalSince1970: 1_700_000_001))
}

@Test("A timestamp that is not milliseconds is dropped, not fatal")
func survivesADateString() throws {
    // One specification calls these date-time strings; a listing must not fail
    // over one that is.
    let json = #"{"id":"1","directoryId":"0","fileName":"Note","isFolder":"Y","updateTime":"2024-01-01 10:00:00"}"#
    let entry = try JSONDecoder().decode(SNEntry.self, from: Data(json.utf8))
    #expect(entry.isFolder)
    #expect(entry.modified == nil)
    #expect(entry.size == nil)
}

@Test("An identifier goes out as a string")
func encodesIdentifiersAsStrings() throws {
    let data = try JSONEncoder().encode(["id": SNFileID(rawValue: 900_000_000_000_000_005)])
    #expect(String(decoding: data, as: UTF8.self) == #"{"id":"900000000000000005"}"#)
}

@Test("The login challenge's timestamp goes back in the form it came")
func echoesTheTimestamp() throws {
    let number = try JSONDecoder().decode(WireEcho.self, from: Data("946684801234".utf8))
    let text = try JSONDecoder().decode(WireEcho.self, from: Data(#""946684801234""#.utf8))
    #expect(String(decoding: try JSONEncoder().encode(number), as: UTF8.self) == "946684801234")
    #expect(String(decoding: try JSONEncoder().encode(text), as: UTF8.self) == #""946684801234""#)
}

// MARK: - The envelope

@Test("A refusal arrives as 200 with success false, and is read by its code")
func readsTheEnvelope() {
    func refusal(_ code: String) -> SNError? {
        do {
            _ = try SNChannel.open(Data(#"{"success":false,"errorCode":"\#(code)","errorMsg":"m"}"#.utf8), as: SNChannel.Nothing.self)
            return nil
        } catch {
            return error as? SNError
        }
    }
    #expect(refusal("E0712") == .sessionExpired)
    #expect(refusal("E0085") == .sessionExpired)
    #expect(refusal("E0019") == .invalidCredentials)
    #expect(refusal("E1760") == .verificationRequired)
    #expect(refusal("E1756") == .invalidVerificationCode)
    #expect(refusal("E0322") == .alreadyExists)
    #expect(refusal("E0321") == .notFound(code: "E0321"))
    #expect(refusal("E0710") == .accountLocked(code: "E0710"))
    #expect(refusal("E9999") == .rejected(code: "E9999", message: "m"))
}

@Test("An answer that is not JSON is malformed, and says what it was")
func refusesNonJSON() {
    #expect(throws: SNError.malformedResponse("not the service's JSON: HTML, 6 bytes")) {
        try SNChannel.open(Data("<html>".utf8), as: SNChannel.Nothing.self)
    }
}

@Test("An answer without success counts only where nothing says otherwise")
func readsAMissingSuccess() throws {
    _ = try SNChannel.open(Data(#"{"innerName":"x"}"#.utf8), as: SNChannel.Nothing.self)
    #expect(throws: SNError.rejected(code: "E1305", message: "")) {
        try SNChannel.open(Data(#"{"errorCode":"E1305"}"#.utf8), as: SNChannel.Nothing.self)
    }
}

@Test("A part of a file is hashed alone, and a part running past the end stops there")
func hashesAPartOfAFile() throws {
    let file = try ScratchFile.write(Data("hello supernote".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    // Python: hashlib.md5(b"supernote").hexdigest()
    let part = try Digests.md5(ofFile: file, offset: 6, length: 9)
    #expect(part.md5 == Digests.md5(Data("supernote".utf8)))
    #expect(part.size == 9)
    let past = try Digests.md5(ofFile: file, offset: 6, length: 100)
    #expect(past.size == 9)
    #expect(try Digests.md5(ofFile: file).md5 == "5b5778d47e5d7cc586801850e65f0d0b")
}
