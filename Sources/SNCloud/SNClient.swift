// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The protocol client for the web API: the tree by identifier, the files in
/// it, and the bytes.
///
/// One actor, laid out by what it is asked about: `+Browsing` for listings,
/// searches and the changes that move entries about, `+Transfers` for the bytes
/// in both directions. What stays here is what they share: the session the
/// token comes from.
///
/// **One of two file APIs.** This is the one the service's web page speaks:
/// folders by identifier, paged listings, no device serial. `SNDeviceClient` is
/// the other — the one the tablets sync through, by path, with the whole tree in
/// one answer. Both run on the same session and the same token.
public actor SNClient {
    let session: SNSession
    let channel: SNChannel

    public init(session: SNSession) {
        self.session = session
        self.channel = session.channel
    }

    func authorized<Payload: Decodable & Sendable>(
        _ path: String,
        body: some Encodable & Sendable,
        changes: Bool,
        timeout: TimeInterval? = nil,
        generation: Int? = nil,
        as payload: Payload.Type = Payload.self
    ) async throws -> Payload {
        try await channel.call(
            path, on: .web, body: body, by: session, changes: changes, timeout: timeout, generation: generation, as: Payload.self
        )
    }

    func authorized(_ path: String, body: some Encodable & Sendable, changes: Bool, generation: Int? = nil) async throws {
        _ = try await authorized(path, body: body, changes: changes, generation: generation, as: SNChannel.Nothing.self)
    }
}

extension SNChannel {
    /// One call with the session's access token on it.
    ///
    /// There is no second attempt with a new token, because there is no new
    /// token to be had without the password. A refusal drops the token — the
    /// one that went out, not whatever is in the store by the time the answer
    /// comes back — and is handed upwards as `sessionExpired`, which is the
    /// host's cue to ask the person to log in again.
    ///
    /// On the apps' host the call also carries the app's own headers — the
    /// protocol version and the device — and, with `channel`, the header the
    /// official app puts on the calls of a sync. The web host gets none of
    /// them: the web page does not send them.
    func call<Payload: Decodable & Sendable>(
        _ path: String,
        on api: SNAPI,
        method: String = "POST",
        body: some Encodable & Sendable,
        by session: SNSession,
        channel withChannel: Bool = false,
        changes: Bool,
        timeout: TimeInterval? = nil,
        generation: Int? = nil,
        as payload: Payload.Type = Payload.self
    ) async throws -> Payload {
        // `generation` pins the call to one login: the token is handed over
        // only while that login is still the current one.
        let epoch = await browser.epoch
        let token = try await session.accessToken(forGeneration: generation)
        let headers = api == .app ? try await session.appHeaders(token: token, channel: withChannel) : [:]
        do {
            return try await call(
                path,
                on: api,
                method: method,
                body: body,
                token: token,
                headers: headers,
                changes: changes,
                timeout: timeout,
                epoch: epoch,
                as: Payload.self
            )
        } catch let error as SNError where error.meansSessionIsGone {
            await session.invalidate(token)
            throw error
        }
    }
}

extension SNChannel {
    /// The signer of a multipart upload's S3 requests: `file/s3/auth` on the
    /// apps' host, with the token, the app's headers and `channel`, as the
    /// official app sends it — `fileServer` handed back as `upload/apply` gave
    /// it, `awsHeaders` empty.
    func s3Signer(session: SNSession, fileServer: WireEcho?, generation: Int? = nil) -> S3Signer {
        { [self] request in
            try await call(
                SNPath.s3Auth,
                on: .app,
                body: S3AuthRequest(
                    fileServer: fileServer,
                    method: request.method,
                    params: request.params,
                    uri: request.key,
                    data: request.body
                ),
                by: session,
                channel: true,
                changes: false,
                generation: generation,
                as: S3Signature.self
            )
        }
    }
}

private struct S3AuthRequest: Encodable {
    let fileServer: WireEcho?
    let method: String
    let params: [String: String]
    let uri: String
    let data: String?

    enum CodingKeys: String, CodingKey { case fileServer, method, params, awsHeaders, uri, data }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fileServer, forKey: .fileServer)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
        try container.encode([String: String](), forKey: .awsHeaders)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(data, forKey: .data)
    }
}
