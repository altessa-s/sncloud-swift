// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import SNCloud
@testable import snctl
import Testing

/// A directory of its own for each test, removed afterwards.
private func scratchHome() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "snctl-test-\(UUID().uuidString)")
}

private func mode(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
}

@Test("Each server keeps its own secrets, the official cloud the plain name")
func namesTheFilePerServer() {
    #expect(FileSecrets.fileName(for: .official) == "secrets.json")
    func name(_ text: String) -> String {
        FileSecrets.fileName(for: .privateCloud(URL(string: text) ?? URL(fileURLWithPath: "/")))
    }
    #expect(name("http://127.0.0.1:19072").hasPrefix("secrets-127.0.0.1-"))
    #expect(name("https://nas.example.com").hasPrefix("secrets-nas.example.com-"))
    #expect(FileSecrets.fileName(for: .officialChina) != FileSecrets.fileName(for: .official))
    // Servers that a host-and-port spelling ran together.
    #expect(name("https://nas:8080") != name("https://nas-8080"))
    #expect(name("http://nas") != name("https://nas"))
    #expect(name("https://nas/a") != name("https://nas/b"))
    // The same server, however its default port is written.
    #expect(name("https://nas") == name("https://nas:443"))
}

@Test("The secrets file is 0600 from its first write, in a 0700 directory, with nothing left beside it")
func writesPrivately() throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let secrets = try FileSecrets(for: .official, home: home)

    try secrets.keep("token", as: .accessToken)
    try secrets.keep("a@example.com", as: .account)

    #expect(try mode(home) & 0o777 == 0o700)
    #expect(try mode(secrets.file) & 0o777 == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == ["secrets.json"])
    #expect(try secrets.secret(.accessToken) == "token")

    try secrets.discard(.accessToken)
    #expect(try secrets.secret(.accessToken) == nil)
    #expect(try secrets.secret(.account) == "a@example.com")
    #expect(try mode(secrets.file) & 0o777 == 0o600, "a rewrite loosened the file")
}

@Test("Two servers in one home do not see each other's token")
func keepsServersApart() throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let official = try FileSecrets(for: .official, home: home)
    let bench = try FileSecrets(
        for: .privateCloud(URL(string: "http://127.0.0.1:19072") ?? URL(fileURLWithPath: "/")), home: home
    )
    try official.keep("official-token", as: .accessToken)
    #expect(try bench.secret(.accessToken) == nil)
}

@Test("A password file is read as password=…, or as the password alone")
func readsAPasswordFile() throws {
    let home = scratchHome()
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = home.appending(path: "pw")

    for (content, expected) in [("account=a@b.c\npassword=s3cret\n", "s3cret"), ("only-this\n", "only-this")] {
        try Data(content.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Terminal.password(fromFile: file.path) == expected)
    }
}

@Test("A name the server gives is a file name here only if it is one component")
func refusesServerNamesThatArePaths() throws {
    #expect(try Commands.localName("Sample.note") == "Sample.note")
    for name in ["", ".", "..", "../../.zshrc", "/etc/hosts", "a/b", "a\\b", "a\u{0}b"] {
        #expect(throws: SNError.self) { try Commands.localName(name) }
    }
}
