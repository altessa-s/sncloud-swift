# Architecture

How the pieces fit, and why the shape is what it is. `API.md` is the protocol
on the wire; this is the code that speaks it. The structure below was confirmed
against the dependency graph of the package — the bridges and the clusters it
surfaces are the ones described here.

## Three layers, two waists

The package is three layers, and almost everything crosses them through two
narrow points rather than many:

```
   SNClient   SNDeviceClient   SNTaskClient   SNDigestClient   SNChangeFeed
        \          \                |               /              /
         \          \               |              /              /
          ────────────────  SNChannel  ───────────────
                   (the one path to the network)
              /          |            |            \
        SNSession   SNRetryPolicy  SNEndpoints   SNTransporting
                              |
                          Transfers
                   (the one path for bytes)
```

- **Clients** know the protocol — which call, which fields, which quirks — and
  nothing about the network. Each one is its own cluster in the graph.
- **`SNChannel`** knows the network and nothing about the protocol: the JSON
  envelope, cookies, the XSRF handshake, the retry policy, the login epoch. Every
  client reaches the wire through `channel.call(...)`; it is the first waist.
- **`Transfers`** knows bytes: S3 single-PUT and multipart, the private cloud's
  form upload, ranged downloads with a hash check. The three clients that move
  bytes hand them to `Transfers`; it is the second waist.

`SNChannel` and `SNFileID` have by far the most edges in the graph. That is not
a pair of god objects — it is the two waists showing through. `SNChannel` is the
single I/O path; `SNFileID` is the one identifier the whole protocol is keyed
on. Both are meant to be central.

## The channel is the only door to the network

`SNClient` (web API, `cloud.supernote.com`), `SNDeviceClient` (device API),
`SNTaskClient` (to-do), `SNDigestClient` (digests) and `SNChangeFeed` (the
socket.io feed) each depend on `SNChannel` by one edge and never touch
`URLSession` themselves. A change to how a request is formed, retried, logged or
redacted happens in one place. The channel in turn depends on `SNSession` (the
token), `SNRetryPolicy`, `SNEndpoints` (the hosts) and the `SNTransporting`
port — so a test swaps the transport under the whole stack at one seam.

## Two counters for one session's life

The channel and the session each guard one half of "is this still the same
session", with two separate counters:

- **`BrowserState.epoch`** (inside `SNChannel`) — the network conversation: the
  cookie jar and the XSRF token. A response that arrives after `forgetAll()` has
  moved the epoch is dropped, so a stale reply cannot seed cookies into a jar a
  logout just cleared. All of this stays within the channel.
- **`SNSession.generation`** — which login attempt is current. Moved by every
  `logIn()` and every `forget()`.

They meet at the one `SNChannel ↔ SNSession` edge. `accessToken(forGeneration:)`
is the seam: it checks the generation and hands over the token in **one
synchronous step inside the actor**, so no login can slip between the check and
the use.

```swift
func accessToken(forGeneration expected: Int?) throws -> String {
    if let expected, expected != generation { throw SNError.notLoggedIn }
    return try accessToken()
}
```

This matters for uploads and other operations spanning several calls. `apply`, each
S3 signature, and `finish` are all pinned to the generation they started under;
a login to another account midway makes the next step throw `notLoggedIn` rather
than finish one account's bytes under another's token.

## Bytes go through Transfers, signed by the channel

`Transfers` cannot sign an S3 request — each part needs a signature from the
server (`file/s3/auth`). The signer is a closure the client builds with
`SNChannel.s3Signer(...)` and passes into `Transfers.send`: the signature travels
back out through the channel, the same path as every other request, and carries
the same `generation`. So a multipart upload signs every part under the login it
began with.

When a multipart upload fails after S3 has accepted parts, those parts sit in
storage — and are billed — until a lifecycle rule clears them, so the failure
path sends an abort. It is sent from a **task of its own**:

```swift
await Task { await self.abort(objectURL, key: key, uploadID: uploadID, signer: signer) }.value
```

If the failure is a cancellation, a request sent from the already-cancelled task
would be cancelled before it left the process; a fresh task has its own
cancellation flag. The original error is re-thrown untouched — the cleanup never
hides what went wrong. The sync-lock release in `SNDeviceClient` is bracketed the
same way, for the same reason.

## What this buys

- One place to change I/O, retries, logging and redaction: `SNChannel`.
- One place to change how bytes move: `Transfers`.
- A transport port (`SNTransporting`) and a secret-store port (`SNSecretStoring`)
  that a host fills and a test doubles.
- Clients that read like the protocol document, because the network and the
  bytes are somewhere else.

## Session isolation and resource limits

Authorized calls capture the browser epoch **before** asking the session for a
token. A reset during token acquisition therefore invalidates the call instead
of attaching an old token to a new cookie conversation. Every paged web, to-do
and digest listing, and both ends of a sync-lock scope, also carry one login
generation. Switching accounts aborts subsequent steps with `notLoggedIn`.
A lock that cannot be released under its original generation expires on the
server's timer; it is never released with the replacement account's token.

A new login attempt removes the previous access token and clears its cache,
including while waiting for email verification. The account is saved before the
new token is published. A failed credential write leaves the session without an
access token; the account name can remain as a hint for another login attempt.

Paged to-do and digest rows are deduplicated before tombstones are removed, so
the last observed deletion wins. Web listings retain their 10,000-page ceiling
but now throw `malformedResponse` on exhaustion instead of returning partial
results. A listing that completes on the final allowed page still succeeds.

Data requests and upload replies use a per-task data delegate on their existing
sessions. It refuses a declared length above 32 MiB and cancels as soon as a
chunk would cross that limit, before appending it or logging the body. Downloads
keep their separate file-size budget and shared connection pool.

The change feed buffers at most 256 announcements. Overflow inserts `.connected`
as a full REST refresh signal, so consumers must relist on every such marker,
including within an existing connection. A socket that supplies no Engine.IO
open frame within 30 seconds is closed with a timeout error. Once the open frame
arrives, the server's heartbeat interval and timeout take over.
