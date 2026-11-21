// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Synchronization
import Testing

@Test("A later tombstone wins over a live row in every marked listing", arguments: 0..<4)
func tombstones(_ kind: Int) async throws {
    let rows = kind < 2 ? (kind == 0 ? "scheduleTask" : "scheduleTaskGroup") : "summaryDOList"
    let id = kind < 2 ? (kind == 0 ? #""taskId":"one""# : #""taskListId":"one""#) : #""id":1"#
    let next = kind < 2 ? (kind == 0 ? "nextPageToken" : "pageToken") : "totalPages"
    let first = kind < 2 ? #""\#(next)":"2""# : #""totalPages":2"#
    let last = kind < 2 ? #""\#(next)":null"# : #""totalPages":2"#
    let script = ScriptedTransport([
        .ok(#"\#(first),"\#(rows)":[{\#(id),"title":"live","isDeleted":"N"}]"#),
        .ok(#"\#(last),"\#(rows)":[{\#(id),"title":"deleted","isDeleted":"Y"}]"#),
    ])
    let session = SNSession(transport: script, secrets: InMemorySecrets([.accessToken: liveToken]))
    switch kind {
    case 0: #expect(try await SNTaskClient(session: session).tasks().isEmpty)
    case 1: #expect(try await SNTaskClient(session: session).lists().isEmpty)
    case 2: #expect(try await SNDigestClient(session: session).groups().isEmpty)
    default: #expect(try await SNDigestClient(session: session).digests(in: "group").isEmpty)
    }
    #expect(script.calls.count == 2)
}

@Test("Web paging retains its starting login across page boundaries")
func pageGeneration() async throws {
    let script = ScriptedTransport([.ok(#""randomCode":"r","timestamp":1"#), .ok(#""token":"new-token""#)])
    let (_, session, _) = loggedInClient(script)
    let client = SNClient(session: session)
    await #expect(throws: SNError.notLoggedIn) {
        _ = try await client.pages { page, generation in
            _ = try await session.accessToken(forGeneration: generation)
            if page == 1 {
                _ = try await session.logIn(account: "new@example.invalid", password: "synthetic")
            }
            return (entries: [1], total: Int64(2), pages: nil)
        }
    }
}

@Test("An endless web listing fails at its ceiling; the final allowed page may finish")
func pageCeiling() async throws {
    let (client, _, _) = loggedInClient(ScriptedTransport([]))
    await #expect(throws: SNError.malformedResponse("the listing ran past 10000 pages")) {
        _ = try await client.pages { _, _ in (entries: [1], total: nil, pages: Int64.max) }
    }
    let entries = try await client.pages { _, _ in
        (entries: [1], total: nil, pages: Int64(SNClient.pageCeiling))
    }
    #expect(entries.count == SNClient.pageCeiling)
}

@Test("A sync scope cannot release another login's lock", arguments: [false, true])
func syncGeneration(_ fails: Bool) async throws {
    let script = ScriptedTransport([.ok(), .ok(#""randomCode":"r","timestamp":1"#), .ok(#""token":"new-token""#), .ok()])
    let session = SNSession(transport: script, secrets: InMemorySecrets([.accessToken: liveToken]))
    let client = SNDeviceClient(session: session)
    let expected: SNError = fails ? .invalidCredentials : .notLoggedIn
    await #expect(throws: expected) {
        try await client.withSyncLock { _ in
            _ = try await session.logIn(account: "new@example.invalid", password: "synthetic")
            if fails { throw SNError.invalidCredentials }
        }
    }
    #expect(!script.calls.contains { $0.url?.path.hasSuffix("synchronous/end") == true })
}

private final class FaultInjectingSecrets: SNSecretStoring {
    let base = InMemorySecrets([.accessToken: "old-token", .account: "old@example.invalid", .clientID: "synthetic"])
    let onTokenRead = Mutex<(@Sendable () -> Void)?>(nil)
    let failingWrite = Mutex<SNSecret?>(nil)
    let failingDiscard = Mutex(false)

    func secret(_ which: SNSecret) throws -> String? {
        let value = try base.secret(which)
        if which == .accessToken {
            let action = onTokenRead.withLock { action in
                defer { action = nil }
                return action
            }
            action?()
        }
        return value
    }

    func keep(_ value: String, as which: SNSecret) throws {
        if failingWrite.withLock({ $0 == which }) { throw SNError.invalidCredentials }
        try base.keep(value, as: which)
    }

    func discard(_ which: SNSecret) throws {
        if failingDiscard.withLock({ $0 }) { throw SNError.invalidCredentials }
        try base.discard(which)
    }
}

@Test("The browser epoch is captured before fetching an authorized token")
func epochBeforeToken() async throws {
    let script = ScriptedTransport([.ok()])
    let secrets = FaultInjectingSecrets()
    let session = SNSession(transport: script, secrets: secrets)
    let browser = await session.channel.browser
    secrets.onTokenRead.withLock { action in
        action = {
            // Hold the session actor at token acquisition while the independent
            // browser actor resets, exactly the former suspension window.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await browser.forgetAll()
                done.signal()
            }
            #expect(done.wait(timeout: .now() + 5) == .success, "Browser reset must finish within five seconds")
        }
    }
    await #expect(throws: SNError.notLoggedIn) {
        _ = try await SNClient(session: session).list()
    }
    #expect(script.requests.isEmpty)
}

@Test("Failed credential writes never publish a mismatched or cached token", arguments: [SNSecret.account, .accessToken])
func credentialFailure(_ failing: SNSecret) async throws {
    let secrets = FaultInjectingSecrets()
    let script = ScriptedTransport([.ok(#""randomCode":"r","timestamp":1"#), .ok(#""token":"new-token""#)])
    let session = SNSession(transport: script, secrets: secrets)
    #expect(try await session.accessToken() == "old-token")
    secrets.failingWrite.withLock { $0 = failing }
    await #expect(throws: SNError.invalidCredentials) {
        _ = try await session.logIn(account: "new@example.invalid", password: "synthetic")
    }
    #expect(try secrets.secret(.accessToken) == nil)
    await #expect(throws: SNError.notLoggedIn) { _ = try await session.accessToken() }
}

@Test("Pending verification clears the preceding account's authorization")
func pendingCredentials() async throws {
    let secrets = FaultInjectingSecrets()
    let script = ScriptedTransport([.ok(#""randomCode":"r","timestamp":1"#), .refused("E1760")])
    let session = SNSession(transport: script, secrets: secrets)
    _ = try await session.accessToken()
    #expect(try await session.logIn(account: "new@example.invalid", password: "synthetic") == .verificationRequired)
    await #expect(throws: SNError.notLoggedIn) { _ = try await session.accessToken() }
}

@Test("A failed token deletion still resets the browser before aborting login")
func loginDiscardFailure() async throws {
    let secrets = FaultInjectingSecrets()
    let script = ScriptedTransport([])
    let session = SNSession(transport: script, secrets: secrets)
    let browser = await session.channel.browser
    let epoch = await browser.epoch
    secrets.failingDiscard.withLock { $0 = true }
    await #expect(throws: SNError.invalidCredentials) {
        _ = try await session.logIn(account: "new@example.invalid", password: "synthetic")
    }
    #expect(await browser.epoch == epoch + 1)
    #expect(script.requests.isEmpty)
}

@Test("A wrong password ends the preceding login as documented")
func failedRelogin() async throws {
    let secrets = FaultInjectingSecrets()
    let script = ScriptedTransport([.ok(#""randomCode":"r","timestamp":1"#), .refused("E0019")])
    let session = SNSession(transport: script, secrets: secrets)
    #expect(try await session.accessToken() == "old-token")
    await #expect(throws: SNError.invalidCredentials) {
        _ = try await session.logIn(account: "new@example.invalid", password: "synthetic")
    }
    #expect(try secrets.secret(.accessToken) == nil)
    await #expect(throws: SNError.notLoggedIn) { _ = try await session.accessToken() }
}
