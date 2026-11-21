// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// What a login came to.
///
/// Frozen, for the reason given on `SNError`.
@frozen
public enum SNLoginOutcome: Sendable, CaseIterable {
    /// The access token is in the store; the client can be used.
    case loggedIn
    /// The service wants the login confirmed with a code it emails to the
    /// account — `E1760`, met on a device or browser it has not seen before.
    /// Call `sendVerificationCode()`, ask the person for the code, then
    /// `verify(code:)`.
    case verificationRequired
}

// Equality spelled out rather than synthesised; see `SNError`.
extension SNLoginOutcome {
    public static func == (lhs: SNLoginOutcome, rhs: SNLoginOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.loggedIn, .loggedIn), (.verificationRequired, .verificationRequired): true
        default: false
        }
    }
}

/// The account: logging in, the access token, logging out.
///
/// The service has no refresh. A login answers with a JWT that lives thirty days
/// on the official cloud and is then refused, and the only way to another one is
/// the password. So unlike `RMCloud`'s token provider there is nothing to buy in
/// the background: this actor holds one token, says when it has run out, and
/// drops it the moment the service refuses it.
///
/// **This is the official app's login.** Supernote Partner logs in with
/// `login/new` on the apps' host as an app (`equipment: 2`) — not with the
/// tablets' `login/equipment`, which binds a device serial to the account. An
/// account keeps several such sessions at once; this one is named by the
/// installation's own `SNDeviceIdentity`, which this actor makes once and keeps.
public actor SNSession {
    /// How much life a token must have left to be worth sending. One that dies
    /// mid-request is a refusal in the middle of a transfer.
    static let expiryMargin: TimeInterval = 5 * 60

    let channel: SNChannel
    private let secrets: any SNSecretStoring
    private let now: @Sendable () -> Date

    private var cachedToken: String?

    /// A login the service wants confirmed by email, between `logIn` and
    /// `verify(code:)`.
    private var pending: PendingVerification?

    /// Which login attempt is the current one.
    ///
    /// An actor does not hold its lock across an await. A login suspends on
    /// several requests, and `forget()` — or a second `logIn` — is free to run
    /// in any of the gaps. Without this, the first attempt could come back and
    /// write its token into the store for an account the person had just
    /// disconnected, or over the newer login that replaced it.
    ///
    /// Moved by every `logIn` and every `forget()`, so each attempt has a
    /// number of its own; the emailed-code steps carry their attempt's number
    /// in `pending`, and every step checks it after every suspension.
    private var generation = 0

    /// The `equipmentNo`s whose sync-lock scope is running on this session.
    /// See `SNDeviceClient.withSyncLock`.
    private var syncLocks: Set<String> = []

    /// The digests a write is running on, from any client on this session.
    /// See `SNDigestClient.update`.
    private var digestWrites: Set<Int64> = []

    /// The number the `channel` header ends with: milliseconds since the epoch,
    /// taken once, as the official client takes it once per process.
    private let started: String

    /// Who this installation is to the service — made the first time it is
    /// asked for, and kept in the store from then on, logins and logouts
    /// notwithstanding.
    public func identity() throws -> SNDeviceIdentity {
        if let kept = try secrets.secret(.clientID), !kept.isEmpty {
            return SNDeviceIdentity(clientID: kept)
        }
        let made = SNDeviceIdentity(clientID: UUID().uuidString.lowercased())
        try secrets.keep(made.clientID, as: .clientID)
        return made
    }

    /// The headers every call to the apps' host carries, as the official
    /// client sets them in its interceptor: the protocol version it speaks and
    /// the device, and — for the calls of a sync — `channel` beside them.
    func appHeaders(token: String?, channel withChannel: Bool) throws -> [String: String] {
        let identity = try identity()
        var headers = [
            "User-Agent": SNRequest.appUserAgent,
            SNRequest.versionHeader: SNRequest.protocolVersion,
            SNRequest.equipmentHeader: identity.equipmentHeader,
        ]
        if withChannel, let token {
            headers[SNRequest.channelHeader] = identity.channel(token: token, started: started)
        }
        return headers
    }

    /// What the socket.io channel is opened with: the token, the device as the
    /// `channel` header names it, and the same per-process number.
    func socketCredentials() throws -> (token: String, type: String, random: String) {
        (try accessToken(), try identity().socketType, started)
    }

    public init(
        endpoints: SNEndpoints = .official,
        transport: any SNTransporting = SNURLSessionTransport(),
        secrets: any SNSecretStoring,
        now: @escaping @Sendable () -> Date = Date.init,
        policy: SNRetryPolicy = .default,
        sleeper: any SNSleeping = SNSystemSleeper()
    ) {
        self.channel = SNChannel(endpoints: endpoints, transport: transport, policy: policy, sleeper: sleeper)
        self.secrets = secrets
        self.now = now
        self.started = String(Int64(now().timeIntervalSince1970 * 1000))
    }

    public var endpoints: SNEndpoints { channel.endpoints }

    /// Whether there is a token that has not run out by its own `exp`. The
    /// service may still have ended the session sooner; the first call says.
    public var isLoggedIn: Bool {
        get throws {
            guard let token = try cachedToken ?? secrets.secret(.accessToken) else { return false }
            return Self.isUsable(token, at: now())
        }
    }

    /// Who the token belongs to, as they typed it at login.
    public var account: String? {
        get throws { try secrets.secret(.account) }
    }

    /// When the token in hand stops being accepted, where it says.
    public var expiry: Date? {
        get throws {
            guard let token = try cachedToken ?? secrets.secret(.accessToken) else { return nil }
            return AccessTokenClaims.expiry(of: token)
        }
    }

    // MARK: - Logging in

    /// Log in with an email address (or a phone number and its country code)
    /// and a password.
    ///
    /// The password never leaves this call: the service hands out a one-time
    /// salt, the password is digested with it (see `Digests.password`), and the
    /// digest is what travels.
    ///
    /// **The login the official app makes**, field for field: on the apps'
    /// host, as `equipment: 2` (an app, not a web page), `loginMethod` 1 for a
    /// phone and 2 for an email address, the platform in `devices`, and the
    /// device in the `equipmentNo` header. The web page's login is a different
    /// body on the other host; this package used it once, and moved to the one
    /// the official client is seen making on the wire.
    public func logIn(account: String, password: String, countryCode: Int? = nil) async throws -> SNLoginOutcome {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !password.isEmpty else { throw SNError.invalidCredentials }
        generation += 1
        let session = generation
        pending = nil
        cachedToken = nil
        // A login is a conversation of its own. Starting a new one ends the
        // last, so that an attempt it overtook cannot put its cookies — which
        // the cookie-backed token lookup would act on — over this one's: the
        // overtaken attempt's answers arrive stamped with an epoch that is gone.
        let epoch = await channel.browser.forgetAll()
        guard session == generation else { throw SNError.notLoggedIn }
        // Reset cookies even if deleting the preceding token fails.
        try secrets.discard(.accessToken)

        let headers = try appHeaders(token: nil, channel: false)
        let challenge = try await channel.call(
            SNPath.randomCode,
            body: ChallengeRequest(account: account, countryCode: countryCode),
            token: nil,
            headers: headers,
            changes: false,
            epoch: epoch,
            as: Challenge.self
        )
        // Overtaken while the salt was on its way: the login it was for has
        // been forgotten or replaced, and sending it would open a session —
        // cookies and all — that nobody asked for any more.
        guard session == generation else { throw SNError.notLoggedIn }
        let request = LoginRequest(
            account: account,
            password: Digests.password(password, salt: challenge.randomCode),
            countryCode: countryCode,
            timestamp: challenge.timestamp,
            devices: try identity().platform
        )
        // A login is not retried on a 5xx: the salt it carries is spent the
        // moment the server reads it, and a second send of the same digest is
        // a wrong password.
        do {
            let answer = try await channel.call(
                SNPath.login, body: request, token: nil, headers: headers, changes: true, epoch: epoch, as: TokenAnswer.self
            )
            try keep(answer.token, for: account, session: session)
            return .loggedIn
        } catch SNError.verificationRequired {
            guard session == generation else { throw SNError.notLoggedIn }
            pending = PendingVerification(attempt: session, epoch: epoch, account: account)
            Log.supernote.info("login wants an emailed code")
            return .verificationRequired
        }
    }

    /// Ask the service to email the code a pending login needs.
    ///
    /// The official app's way: `user/mail/validcode` with the address and a
    /// language, answered with the key the code is checked against. The web
    /// page's way — a pre-auth token and a signature over it — is not what the
    /// app sends, and this package no longer sends it either.
    ///
    /// Email only: a phone number would go by text message, which is a flow of
    /// its own this package has not been asked for.
    public func sendVerificationCode() async throws {
        guard let verification = pending, verification.account.contains("@") else {
            throw SNError.noVerificationPending
        }
        try await overtakenAsNotPending(verification.attempt) { try await requestCode(for: verification) }
    }

    private func requestCode(for pendingVerification: PendingVerification) async throws {
        var verification = pendingVerification
        let sent = try await channel.call(
            SNPath.mailCode,
            body: MailCodeRequest(email: verification.account, language: SNRequest.language),
            token: nil,
            headers: try appHeaders(token: nil, channel: false),
            changes: true,
            epoch: verification.epoch,
            as: CodeKey.self
        )
        // The attempt may have been forgotten or replaced while the code was on
        // its way; restoring it then would revive a login the person ended.
        guard pending?.attempt == verification.attempt, generation == verification.attempt else {
            throw SNError.noVerificationPending
        }
        verification.validCodeKey = sent.validCodeKey
        pending = verification
        Log.supernote.info("verification code sent")
    }

    /// Finish a pending login with the code the person read from their email.
    ///
    /// A wrong code leaves the login pending — the service allows five tries in
    /// five minutes — and is answered `invalidVerificationCode`.
    public func verify(code: String) async throws {
        guard let verification = pending, let key = verification.validCodeKey else {
            throw SNError.noVerificationPending
        }
        try await overtakenAsNotPending(verification.attempt) {
            try await completeLogin(verification, key: key, code: code)
        }
    }

    /// A step of the emailed-code login, with whatever it failed with said in
    /// the step's own terms when the login it belonged to was forgotten or
    /// replaced meanwhile: there is no verification pending any more, which
    /// is truer than "not logged in" for a person holding a code.
    private func overtakenAsNotPending(_ attempt: Int, _ step: () async throws -> Void) async throws {
        do {
            try await step()
        } catch {
            guard attempt == generation else { throw SNError.noVerificationPending }
            throw error
        }
    }

    private func completeLogin(_ verification: PendingVerification, key: String, code: String) async throws {
        let session = verification.attempt
        guard session == generation else { throw SNError.noVerificationPending }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = try appHeaders(token: nil, channel: false)
        // The app checks the code first and logs in with it second; a wrong
        // code is refused by the first call and leaves the login pending.
        try await channel.call(
            SNPath.checkCode,
            body: CheckCodeRequest(validCode: code, validCodeKey: key),
            token: nil,
            headers: headers,
            changes: false,
            epoch: verification.epoch
        )
        guard session == generation else { throw SNError.noVerificationPending }
        let answer = try await channel.call(
            SNPath.appCodeLogin,
            body: CodeLoginRequest(
                email: verification.account,
                validCode: code,
                validCodeKey: key,
                devices: try identity().platform
            ),
            token: nil,
            headers: headers,
            changes: true,
            epoch: verification.epoch,
            as: OptionalTokenAnswer.self
        )
        guard session == generation else { throw SNError.noVerificationPending }
        guard let token = answer.token, !token.isEmpty else {
            throw SNError.malformedResponse("the verified login answered with no token")
        }
        try keep(token, for: verification.account, session: session)
        if pending?.attempt == session { pending = nil }
    }

    /// Log out at the service, then here — whatever the service said.
    ///
    /// A logout that cannot reach the server still forgets the token: the
    /// person asked for this machine to stop reaching the account, and that
    /// much does not depend on the network. The server's refusal is thrown
    /// afterwards, so a host can say the session may still be live there. A
    /// token the service has already stopped accepting is logged out by
    /// definition.
    ///
    /// A login made while the logout was on its way is left alone: the logout
    /// was about the session it started with, and forgetting afterwards would
    /// erase the one the person has just made.
    public func logOut() async throws {
        let session = generation
        let token = try cachedToken ?? secrets.secret(.accessToken)
        var failure: (any Error)?
        if let token {
            do {
                try await channel.call(
                    SNPath.logout, body: EmptyBody(), token: token,
                    headers: try appHeaders(token: token, channel: false), changes: true
                )
            } catch SNError.sessionExpired {
                // Nothing left to end.
            } catch {
                failure = error
            }
        }
        // Overtaken by a login: the session this logout was about is gone, and
        // its answer — whatever it was — is news about nothing current.
        guard session == generation else { return }
        try await forget()
        if let failure { throw failure }
    }

    /// Forget the session here, and only here: the token, the account, the
    /// cookies and anything pending.
    ///
    /// The store is emptied before anything suspends: a call arriving in the
    /// gap would otherwise read the token straight back into the cache this
    /// has just cleared, and stay logged in after the forgetting.
    public func forget() async throws {
        generation += 1
        cachedToken = nil
        pending = nil
        var failure: (any Error)?
        do { try secrets.discard(.accessToken) } catch { failure = error }
        do { try secrets.discard(.account) } catch { failure = failure ?? error }
        await channel.browser.forgetAll()
        if let failure { throw failure }
    }

    /// Which login the session is on — for an operation of several calls that
    /// must not finish under a different account than it started with.
    func loginGeneration() -> Int { generation }

    /// The token to send, but only while the login `expected` is still the
    /// current one — checked and handed over in one step, so that no login can
    /// slip in between. `nil` asks for whichever is current.
    func accessToken(forGeneration expected: Int?) throws -> String {
        if let expected, expected != generation { throw SNError.notLoggedIn }
        return try accessToken()
    }

    // MARK: - The token, for the client

    /// The token to send, or why there is none.
    func accessToken() throws -> String {
        if let cachedToken, Self.isUsable(cachedToken, at: now()) { return cachedToken }
        guard let stored = try secrets.secret(.accessToken) else { throw SNError.notLoggedIn }
        guard Self.isUsable(stored, at: now()) else {
            // Dead by its own word: kept, it would be sent and refused on every
            // call until somebody noticed.
            try? secrets.discard(.accessToken)
            cachedToken = nil
            throw SNError.sessionExpired
        }
        cachedToken = stored
        return stored
    }

    /// Drop `refused` after the service turned it down.
    ///
    /// Only that token: the client runs calls side by side, and a login that
    /// completed between a refusal going out and coming back put a new token in
    /// the store which this refusal is not about.
    func invalidate(_ refused: String) {
        if cachedToken == refused { cachedToken = nil }
        if (try? secrets.secret(.accessToken)) == refused {
            try? secrets.discard(.accessToken)
        }
        Log.supernote.info("access token refused by the service: dropped")
    }

    // MARK: - Inside

    /// A token is usable while its `exp` is more than a margin away. One that
    /// names no `exp` is taken at its word: a private cloud's device-style
    /// token does not expire, and the service will say so if it disagrees.
    static func isUsable(_ token: String, at now: Date) -> Bool {
        guard let expiry = AccessTokenClaims.expiry(of: token) else { return true }
        return expiry.timeIntervalSince(now) > expiryMargin
    }

    private struct PendingVerification {
        let attempt: Int
        /// The browser conversation the login began, which its emailed-code
        /// steps continue.
        let epoch: Int
        let account: String
        var validCodeKey: String?
    }
}

// MARK: - Wire shapes

private struct ChallengeRequest: Encodable {
    let account: String
    let countryCode: Int?

    enum CodingKeys: String, CodingKey { case account, countryCode }

    /// `countryCode` as an explicit null, as the app sends it.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        if let countryCode { try container.encode(countryCode, forKey: .countryCode) } else {
            try container.encodeNil(forKey: .countryCode)
        }
    }
}

private struct Challenge: Decodable {
    let randomCode: String
    let timestamp: WireEcho
}

/// The official app's login body, nulls and all: the app sends `countryCode`,
/// `equipmentNo` and `browser` as explicit nulls, and an encoder that dropped
/// them would be sending a body nobody has seen accepted.
private struct LoginRequest: Encodable {
    let account: String
    let password: String
    let countryCode: Int?
    let timestamp: WireEcho
    let devices: String

    enum CodingKeys: String, CodingKey {
        case account, equipment, loginMethod, password, countryCode, equipmentNo, timestamp, browser, language, devices
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(2, forKey: .equipment)
        // 1 for a phone number — the one kind of account a country code goes
        // with — and 2 for everything else.
        try container.encode(countryCode == nil ? 2 : 1, forKey: .loginMethod)
        try container.encode(password, forKey: .password)
        if let countryCode { try container.encode(countryCode, forKey: .countryCode) } else {
            try container.encodeNil(forKey: .countryCode)
        }
        try container.encodeNil(forKey: .equipmentNo)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeNil(forKey: .browser)
        try container.encode(SNRequest.language, forKey: .language)
        try container.encode(devices, forKey: .devices)
    }
}

private struct MailCodeRequest: Encodable {
    let email: String
    let language: String
}

private struct CodeKey: Decodable {
    let validCodeKey: String
}

private struct CheckCodeRequest: Encodable {
    let validCode: String
    let validCodeKey: String
}

/// `user/sms/login`, which the app uses for an emailed code as well: the
/// telephone and country code are null for an email address.
private struct CodeLoginRequest: Encodable {
    let email: String
    let validCode: String
    let validCodeKey: String
    let devices: String

    enum CodingKeys: String, CodingKey {
        case countryCode, equipment, telephone, validCode, validCodeKey, devices, email
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .countryCode)
        try container.encode(2, forKey: .equipment)
        try container.encodeNil(forKey: .telephone)
        try container.encode(validCode, forKey: .validCode)
        try container.encode(validCodeKey, forKey: .validCodeKey)
        try container.encode(devices, forKey: .devices)
        try container.encode(email, forKey: .email)
    }
}

private struct TokenAnswer: Decodable {
    let token: String
}

private struct OptionalTokenAnswer: Decodable {
    let token: String?
}

// Claims a session keeps for the clients on it, so that two of them do not
// step on one another.
extension SNSession {
    func claimSyncLock(for equipmentNo: String) -> Bool {
        syncLocks.insert(equipmentNo).inserted
    }

    func releaseSyncLock(for equipmentNo: String) {
        syncLocks.remove(equipmentNo)
    }

    func claimDigestWrite(_ id: Int64) -> Bool {
        digestWrites.insert(id).inserted
    }

    func releaseDigestWrite(_ id: Int64) {
        digestWrites.remove(id)
    }
}

extension SNSession {
    private func keep(_ token: String, for account: String, session: Int) throws {
        guard !token.isEmpty else { throw SNError.malformedResponse("the login answered with no token") }
        guard session == generation else {
            Log.supernote.info("a login finished after the session was forgotten: dropping its token")
            throw SNError.notLoggedIn
        }
        // The account is metadata; publish the usable token only after it
        // is saved. A failed write leaves no token paired with another account.
        try secrets.keep(account, as: .account)
        try secrets.keep(token, as: .accessToken)
        cachedToken = token
        Log.supernote.info("logged in, access token \(token, .secret)")
    }
}
