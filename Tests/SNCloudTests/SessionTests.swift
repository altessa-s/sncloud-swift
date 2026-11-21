// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Testing

private let challenge = ScriptedTransport.Reply.ok(#""randomCode":"testSalt","timestamp":946684801234"#)

private func freshSecrets() -> InMemorySecrets {
    InMemorySecrets([.clientID: testClientID])
}

@Test("A login is the official app's: on the apps' host, as an app, with the device in the headers")
func logsIn() async throws {
    let transport = ScriptedTransport([challenge, .ok(#""token":"\#(liveToken)""#)])
    let secrets = freshSecrets()
    let session = SNSession(transport: transport, secrets: secrets)

    #expect(try await session.logIn(account: " a@example.com ", password: "correct horse") == .loggedIn)

    let calls = transport.calls
    #expect(calls.map(\.url?.absoluteString) == [
        "https://viewer.supernote.com/api/official/user/query/random/code",
        "https://viewer.supernote.com/api/official/user/account/login/new",
    ])
    #expect(transport.handshakes == 0, "the apps' host was asked for an XSRF token")

    let salt = calls[0].jsonBody
    #expect(salt["account"] as? String == "a@example.com")
    #expect(salt["countryCode"] is NSNull, "the app sends countryCode as an explicit null")

    let login = calls[1].jsonBody
    #expect(login["account"] as? String == "a@example.com")
    #expect(login["password"] as? String == "250c1bf6d6911e208059ca108051b4f8946aca59a305752d4ded843743639e98")
    #expect(login["timestamp"] as? Int64 == 946_684_801_234)
    #expect(login["equipment"] as? Int == 2)
    #expect(login["loginMethod"] as? Int == 2)
    #expect(login["language"] as? String == "EN")
    #expect(login["devices"] as? String == SNDeviceIdentity.currentPlatform)
    #expect(login["equipmentNo"] is NSNull)
    #expect(login["browser"] is NSNull)
    #expect(!String(decoding: calls[1].httpBody ?? Data(), as: UTF8.self).contains("correct horse"))

    for call in calls {
        #expect(call.value(forHTTPHeaderField: "version") == "202407")
        #expect(call.value(forHTTPHeaderField: "equipmentNo") == "\(SNDeviceIdentity.currentPlatform)_\(testClientID)")
        #expect(call.value(forHTTPHeaderField: "User-Agent") == "Dart/3.8 (dart:io)")
        #expect(call.value(forHTTPHeaderField: "channel") == nil, "channel went out before there was a token")
    }

    #expect(try secrets.secret(.accessToken) == liveToken)
    #expect(try secrets.secret(.account) == "a@example.com")
    #expect(try await session.isLoggedIn)
}

@Test("A phone login names its country and says it is a phone")
func logsInWithAPhone() async throws {
    let transport = ScriptedTransport([challenge, .ok(#""token":"\#(liveToken)""#)])
    let session = SNSession(transport: transport, secrets: freshSecrets())
    _ = try await session.logIn(account: "5551234", password: "pw", countryCode: 1)
    #expect(transport.calls[0].jsonBody["countryCode"] as? Int == 1)
    #expect(transport.calls[1].jsonBody["loginMethod"] as? Int == 1)
    #expect(transport.calls[1].jsonBody["countryCode"] as? Int == 1)
}

@Test("The installation's identifier is made once and outlives a logout")
func keepsTheClientID() async throws {
    let secrets = InMemorySecrets()
    let session = SNSession(transport: ScriptedTransport([]), secrets: secrets)
    let first = try await session.identity()
    #expect(UUID(uuidString: first.clientID) != nil)
    #expect(first.clientID == first.clientID.lowercased())
    try await session.forget()
    #expect(try await session.identity() == first)
    #expect(first.equipmentNo == "\(first.platform)-\(first.clientID)")
    #expect(first.equipmentHeader == "\(first.platform)_\(first.clientID)")
}

@Test("A private cloud is spoken to on its one host, with no XSRF")
func logsInToAPrivateCloud() async throws {
    let transport = ScriptedTransport([challenge, .ok(#""token":"\#(liveToken)""#)])
    let session = SNSession(
        endpoints: .privateCloud(.constant("http://192.168.1.10:8080")),
        transport: transport,
        secrets: freshSecrets()
    )
    _ = try await session.logIn(account: "a@example.com", password: "pw")
    #expect(transport.handshakes == 0)
    #expect(transport.calls.first?.url?.absoluteString == "http://192.168.1.10:8080/api/official/user/query/random/code")
}

@Test("A wrong password is said once and not asked again")
func refusesAWrongPassword() async throws {
    // The account locks after six; a retry would spend them.
    let transport = ScriptedTransport([challenge, .refused("E0019", "wrong password")])
    let sleeper = RecordingSleeper()
    let session = SNSession(transport: transport, secrets: freshSecrets(), sleeper: sleeper)
    await #expect(throws: SNError.invalidCredentials) {
        _ = try await session.logIn(account: "a@example.com", password: "nope")
    }
    #expect(transport.calls.count == 2)
    #expect(sleeper.delays.isEmpty)
    #expect(try await !session.isLoggedIn)
}

@Test("A login the service wants confirmed goes by emailed code, the way the app does it")
func logsInWithAnEmailedCode() async throws {
    let transport = ScriptedTransport([
        challenge,
        .refused("E1760", "verify"),
        .ok(#""validCodeKey":"key-42""#),
        .ok(),
        .ok(#""token":"\#(liveToken)""#),
    ])
    let secrets = freshSecrets()
    let session = SNSession(transport: transport, secrets: secrets)

    #expect(try await session.logIn(account: "user@example.com", password: "pw") == .verificationRequired)
    #expect(try secrets.secret(.accessToken) == nil)

    try await session.sendVerificationCode()
    let send = transport.calls[2]
    #expect(send.url?.path == "/api/user/mail/validcode")
    #expect(send.jsonBody["email"] as? String == "user@example.com")
    #expect(send.jsonBody["language"] as? String == "EN")

    try await session.verify(code: " 123456 ")
    let check = transport.calls[3]
    #expect(check.url?.path == "/api/user/check/validcode")
    #expect(check.jsonBody["validCode"] as? String == "123456")
    #expect(check.jsonBody["validCodeKey"] as? String == "key-42")
    let login = transport.calls[4]
    #expect(login.url?.path == "/api/user/sms/login")
    #expect(login.jsonBody["email"] as? String == "user@example.com")
    #expect(login.jsonBody["validCodeKey"] as? String == "key-42")
    #expect(login.jsonBody["equipment"] as? Int == 2)
    #expect(login.jsonBody["telephone"] is NSNull)
    #expect(try secrets.secret(.accessToken) == liveToken)

    await #expect(throws: SNError.noVerificationPending) { try await session.verify(code: "x") }
}

@Test("A wrong code leaves the login pending for another try")
func keepsTheLoginPendingAfterAWrongCode() async throws {
    let transport = ScriptedTransport([
        challenge, .refused("E1760"), .ok(#""validCodeKey":"k""#),
        .refused("E1756"),
        .ok(), .ok(#""token":"\#(liveToken)""#),
    ])
    let session = SNSession(transport: transport, secrets: freshSecrets())
    _ = try await session.logIn(account: "user@example.com", password: "pw")
    try await session.sendVerificationCode()
    await #expect(throws: SNError.invalidVerificationCode) { try await session.verify(code: "wrong") }
    try await session.verify(code: "right")
    #expect(try await session.isLoggedIn)
}

@Test("A code cannot be asked for without a login waiting for one")
func refusesACodeWithNothingPending() async throws {
    let session = SNSession(transport: ScriptedTransport([]), secrets: freshSecrets())
    await #expect(throws: SNError.noVerificationPending) { try await session.sendVerificationCode() }
}

@Test("A token past its own expiry is dropped and reported as an ended session")
func dropsAnExpiredToken() async throws {
    let dead = syntheticToken(claims: #"{"exp":1000}"#)
    let secrets = InMemorySecrets([.accessToken: dead, .account: "a@example.com"])
    let session = SNSession(transport: ScriptedTransport([]), secrets: secrets)
    #expect(try await !session.isLoggedIn)
    await #expect(throws: SNError.sessionExpired) { _ = try await session.accessToken() }
    #expect(try secrets.secret(.accessToken) == nil)
    #expect(try secrets.secret(.account) == "a@example.com")
}

@Test("Logging out forgets the token even when the service cannot be reached")
func forgetsOnLogoutWhateverTheServiceSays() async throws {
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com", .clientID: testClientID])
    let session = SNSession(transport: ScriptedTransport([.init(status: 503)]), secrets: secrets)
    await #expect(throws: SNError.http(status: 503, path: "/api/user/logout")) { try await session.logOut() }
    #expect(try secrets.secret(.accessToken) == nil)
    #expect(try secrets.secret(.account) == nil)
    #expect(try secrets.secret(.clientID) == testClientID, "the installation's identity went with the session")
}

@Test("A session the service already ended logs out without complaint")
func logsOutOfAnEndedSession() async throws {
    let secrets = InMemorySecrets([.accessToken: liveToken])
    let session = SNSession(transport: ScriptedTransport([.refused("E0712")]), secrets: secrets)
    try await session.logOut()
    #expect(try secrets.secret(.accessToken) == nil)
}

@Test("A token is handed over for a login only while that login is the current one")
func pinsATokenToItsLogin() async throws {
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com"])
    let session = SNSession(transport: ScriptedTransport([]), secrets: secrets, sleeper: RecordingSleeper())
    let login = await session.loginGeneration()

    #expect(try await session.accessToken(forGeneration: login) == liveToken)
    // `forget()` begins the next login's turn, as `logIn` does.
    try await session.forget()
    try secrets.keep(liveToken, as: .accessToken)
    await #expect(throws: SNError.notLoggedIn) { try await session.accessToken(forGeneration: login) }
    #expect(try await session.accessToken(forGeneration: nil) == liveToken)
}
