// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog
@testable import SNCloud
import Testing

// MARK: - Contracts with what is already out there

@Test("The secrets' names are Keychain accounts, and do not move")
func pinsTheSecretNames() {
    #expect(SNSecret.accessToken.rawValue == "accessToken")
    #expect(SNSecret.account.rawValue == "account")
    #expect(SNSecret.clientID.rawValue == "clientID")
    #expect(SNSecret.allCases.count == 3)
}

@Test("The log category is the one a log stream is filtered by")
func pinsTheLogCategory() {
    #expect(LogCategory.supernote.rawValue == "supernote")
}

// MARK: - Hosts

@Test("The official cloud is the apps' host and the web host; only the web one asks for XSRF")
func knowsWhoWantsXSRF() {
    #expect(SNEndpoints.official.app("file/2/files/list_folder").absoluteString
        == "https://viewer.supernote.com/api/file/2/files/list_folder")
    #expect(SNEndpoints.official.web("file/list/query").absoluteString == "https://cloud.supernote.com/api/file/list/query")
    #expect(SNEndpoints.official.webUsesXSRF)
    #expect(SNEndpoints.officialChina.appHost.host() == "viewer.supernote.com.cn")
    let nas = SNEndpoints.privateCloud(.constant("https://nas.example.com"))
    #expect(!nas.webUsesXSRF)
    #expect(nas.appHost == nas.webHost)
}

@Test("A host override is taken only where a token may go")
func guardsTheHostOverride() {
    #expect(SNEndpoints.fromEnvironment([:]) == .official)
    let fake = SNEndpoints.fromEnvironment(["SNCLOUD_HOST": "https://fake.example.com"])
    #expect(fake.appHost.host() == "fake.example.com")
    #expect(fake.webHost.host() == "fake.example.com")
    #expect(SNEndpoints.fromEnvironment(["SNCLOUD_HOST": "http://127.0.0.1:8080"]).appHost.port == 8080)
    // Plain HTTP anywhere but the loopback hands the tokens to whoever is on the way.
    #expect(SNEndpoints.fromEnvironment(["SNCLOUD_HOST": "http://evil.example.com"]) == .official)
    #expect(!SNEndpoints.fromEnvironment(["SNCLOUD_XSRF": "off"]).webUsesXSRF)
}

// MARK: - Redirects

@Test("Credentials do not follow a redirect off their origin")
func stripsCredentialsOffOrigin() throws {
    var request = URLRequest(url: .constant("https://storage.example.com/obj"))
    request.setValue("token", forHTTPHeaderField: "x-access-token")
    request.setValue("xsrf", forHTTPHeaderField: "X-XSRF-TOKEN")
    request.setValue("XSRF-TOKEN=xsrf", forHTTPHeaderField: "Cookie")
    request.setValue("ua", forHTTPHeaderField: "User-Agent")

    let away = try #require(Redirects.following(request, from: .constant("https://cloud.supernote.com/api/x")))
    #expect(away.value(forHTTPHeaderField: "x-access-token") == nil)
    #expect(away.value(forHTTPHeaderField: "X-XSRF-TOKEN") == nil)
    #expect(away.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(away.value(forHTTPHeaderField: "User-Agent") == "ua")

    let home = try #require(Redirects.following(request, from: .constant("https://STORAGE.example.com:443/other")))
    #expect(home.value(forHTTPHeaderField: "x-access-token") == "token")
}

// MARK: - The wire log

@Test("The wire log masks every credential header and never prints a login body")
func masksTheWire() {
    #expect(SNWireLog.tag(for: "x-access-token") == .secret)
    #expect(SNWireLog.tag(for: "X-XSRF-TOKEN") == .secret)
    #expect(SNWireLog.tag(for: "Cookie") == .secret)
    #expect(SNWireLog.tag(for: "Set-Cookie") == .secret)
    #expect(SNWireLog.tag(for: "Authorization") == .secret)
    // The official app's `channel` starts with the access token.
    #expect(SNWireLog.tag(for: "channel") == .secret)
    #expect(SNWireLog.tag(for: "Content-Type") == .public)

    #expect(SNWireLog.carriesCredentialBody(.constant("https://cloud.supernote.com/api/official/user/account/login/new")))
    #expect(SNWireLog.carriesCredentialBody(.constant("https://cloud.supernote.com/api/official/user/sms/login")))
    #expect(SNWireLog.carriesCredentialBody(.constant("https://viewer.supernote.com/api/user/mail/validcode")))
    #expect(SNWireLog.carriesCredentialBody(.constant("https://viewer.supernote.com/api/user/check/validcode")))
    #expect(!SNWireLog.carriesCredentialBody(.constant("https://cloud.supernote.com/api/file/list/query")))

    #expect(SNWireLog.safe(.constant("https://s3.example.com/obj?X-Amz-Signature=secret&a=b")) == "https://s3.example.com/obj (+2 query items)")
}

// MARK: - Retry policy

@Test("Only the network, a 5xx and an explicit wait are retried")
func retriesTransientFailures() {
    let policy = SNRetryPolicy.default
    #expect(policy.shouldRetry(.transport(code: -1009)))
    #expect(policy.shouldRetry(.http(status: 503, path: "/")))
    #expect(policy.shouldRetry(.rateLimited(retryAfter: nil)))
    #expect(!policy.shouldRetry(.invalidCredentials))
    #expect(!policy.shouldRetry(.rejected(code: "E0078", message: "")))
    #expect(!policy.shouldRetry(.http(status: 400, path: "/")))

    #expect(policy.shouldRetryChange(.rateLimited(retryAfter: 1)))
    #expect(!policy.shouldRetryChange(.http(status: 503, path: "/")))
    #expect(!policy.shouldRetryChange(.transport(code: -1001)))
}

@Test("The server's Retry-After outranks the formula, under the ceiling")
func honoursRetryAfter() {
    let policy = SNRetryPolicy.default
    #expect(policy.delay(beforeAttempt: 2, retryAfter: 3) == .seconds(3))
    #expect(policy.delay(beforeAttempt: 2, retryAfter: 3600) == policy.maxDelay)
    // 300 ms × 3, compared in seconds: the product is not exact in binary.
    #expect(abs(policy.delay(beforeAttempt: 3, retryAfter: nil, random: { _ in 0 }).snSeconds - 0.9) < 1e-9)
}
