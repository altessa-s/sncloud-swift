# SNCloud

SNCloud is a Swift client for Supernote Cloud and Supernote Private Cloud. It supports login, file transfers,
the recycle bin, to-do lists, digests and change notifications. The package exposes both the web file API
and the path-based API used for device sync. Its public types use the `SN` prefix so applications can link it
alongside [rmcloud-swift](https://github.com/altessa-s/rmcloud-swift).

## Documents

| | |
|---|---|
| [`docs/API.md`](docs/API.md) | The protocol as it is understood: the hosts, the XSRF handshake, the envelope and its error codes, the login and its digest, the emailed-code flow, the file calls, the two upload protocols, the recycle bin and PNG export, the to-do and digest APIs, the socket.io change feed. |
| [`docs/architecture.md`](docs/architecture.md) | How the code is shaped: the three layers (clients, `SNChannel`, `Transfers`), the two waists everything crosses through, and the two counters — the channel's browser epoch and the session's login generation — that guard one session's life. |

## What it depends on

[`RedactLog`](https://github.com/altessa-s/redactlog-swift), for the lines it writes, pinned to a release tag (`exact: "0.9.0"`) — the same one
`rmcloud-swift` pins. Nothing else.

- **The secrets arrive through a port.** `SNSecretStoring` asks for `accessToken`, `account` and `clientID` by name — the last is the installation's
  UUID, kept across logouts so the account sees one device. The raw values are Keychain account names and do not move.
- **The password is not a secret this package keeps.** It is digested with a one-time salt and forgotten in the same call. The service has no
  refresh, so a session it ends — after thirty days on the official cloud — takes the password again. The alternative was holding the password,
  and that is not a trade to make on a host's behalf.
- **Progress is a closure.** `TransferProgress` is the same typealias `RMCloud` declares, so the two are one type.
- **Diagnostics go to whatever the host installed.** `Log.supernote` on `RedactLog`.

## Design

**Two file APIs, one login.** `SNClient` speaks the web page's API on `cloud.supernote.com` — folders by identifier, paged listings — with the
XSRF handshake it insists on. `SNDeviceClient` speaks the one the official app and the tablets sync through — by path, the whole tree in one
answer, a content hash on every entry, uploads that answer with the new file's identifier, downloads by byte range. Both run on one token. The
device API's sync lock is taken only inside `withSyncLock { … }`. Paths differ: the web API shows `Note`, the device API `NOTE/Note`.

**The recycle bin is the web API's.** `SNClient.delete` puts entries in the bin, and `recycleBin`, `restore`, `deleteForever` and `emptyRecycleBin`
work on it. `SNDeviceClient.delete` does not: the device API removes the row outright.

**Changes are announced, not recorded.** `SNChangeFeed` opens the socket.io channel the official app keeps open — Engine.IO 3, a signed handshake,
a heartbeat that makes the server push — and hands out what it announces about files, the to-do list and digests, as an `AsyncThrowingStream`.
The server queues an announcement per connection and loses the queue with the connection, so it is a signal to look again, never the record:
a stream begins with `.connected`, and that is when to list. Its buffer holds at most 256 announcements; an overflow emits another
`.connected` to request a full refresh. A connection that sends no Engine.IO open frame within 30 seconds ends with a timeout.
Device, task and digest requests send the installation's channel identity, so the server suppresses their
notifications on that installation's feed. Web requests can produce a notification on the same feed.

**The web host wants a browser.** Every call to `cloud.supernote.com` carries an XSRF token from `GET /api/csrf` and the cookie it pairs with;
the apps' host gets neither, as from the official app. The jar is this package's, not `HTTPCookieStorage.shared`: a logout empties it and a test
can read it. A 403 is met with a fresh token, once.

**To-dos and digests are REST.** `SNTaskClient` and `SNDigestClient` speak to the apps' host as the official app does, but these
two APIs, unlike the rest, use GET, PUT and DELETE and put an identifier in the path. A task update can clear omitted fields, so SNCloud sends the whole task;
a list's delete takes its tasks with it; and the to-do listing is always read whole, because the server's delta never shows
deletions and, before service image 26.10.09, did not keep to the account asking.

**Most refusals are 200.** Every answer is `{"success", "errorCode", "errorMsg", …}`, and a wrong password, an ended session and a missing file all
arrive with HTTP 200. `SNError` reads the code; one it does not know is carried as `.rejected(code:message:)` with the service's own sentence.

**An ended session is final.** `E0712`, `E0085` or a 401 drops the token that went out — that one, not whatever is in the store by then — and
surfaces as `.sessionExpired`, the host's cue to ask for the password.

**Breaking login behavior:** Starting a nonempty `logIn` attempt clears the preceding token and browser cookies. A wrong password,
network failure, or pending verification leaves the previous account logged out. If deleting the stored token fails, the attempt throws
after clearing the cookies; the store may still contain the previous token. Account metadata remains available as a login hint.

**Reads are retried; changes are not.** A listing that met a 5xx is asked again. A copy that met one may well have been made, so it is not sent a
second time; only a 429, which says nothing was done, is waited out.

**Downloads are checked.** The bytes come from a signed storage URL with no token on it, held to the size the listing declared, and compared with
the MD5 the service declared before anybody sees them — an expired signature has been seen to answer 200 with an XML error document.

**Uploads.** On S3, files up to 8 MiB use one signed PUT. Larger files use multipart upload with a service-issued
signature for each operation. Private Cloud accepts a multipart form and can provide a part URL for larger files.

**The wire can be read.** `SNCLOUD_WIRE_LOG=headers` or `bodies` — and at `bodies` the to-do titles and digest texts are printed as
they are: they are the account's content, not credentials. Credentials are masked, query strings are dropped, and the login calls' bodies are
never printed at any level. Redact filenames, titles, digest text and account details before sharing logs.

**The host can be pointed elsewhere.** `SNCLOUD_HOST` (HTTPS anywhere, plain HTTP on the loopback only) and `SNCLOUD_XSRF=off`, through
`SNEndpoints.fromEnvironment()` — in a debug build. A private cloud a person owns is `SNEndpoints.privateCloud(_:)`, and there plain HTTP is
allowed: on a home network it is what such a server speaks.

**Errors are frozen.** Every public enum is `@frozen`, with `==` spelled out so a binary framework exports it.

## Using this package

Add SNCloud to your package manifest.

```swift
dependencies: [
    .package(url: "https://github.com/altessa-s/sncloud-swift.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [.product(name: "SNCloud", package: "sncloud-swift")]),
]
```

Logging in, with the emailed code the official cloud asks for on a new device:

```swift
let session = SNSession(secrets: keychain)               // the host's store, conforming to SNSecretStoring
switch try await session.logIn(account: email, password: password) {
case .loggedIn:
    break
case .verificationRequired:
    try await session.sendVerificationCode()
    try await session.verify(code: await askForCode())
}
```

Reading and writing:

```swift
let client = SNClient(session: session)
for entry in try await client.list(.root) where !entry.isFolder {
    let file = try await client.download(entry)           // a temporary file the caller owns
    …
}
let folder = try await client.createFolder(named: "Inbox from Mac")
try await client.upload(contentsOf: pdf, to: folder.id) { sent, total in … }
let notebook = try await client.pdf(ofNote: noteID)      // rendered by the service
let pages = try await client.pngs(ofNote: noteID)        // one PNG per page
let binned = try await client.recycleBin()               // what `delete` put there
try await client.restore(binned.map(\.id))
```

The device API, on the same session:

```swift
let device = SNDeviceClient(session: session)              // MACOS-<uuid>, kept in the store
let tree = try await device.list(path: "/", recursive: true)  // everything, flat, with content hashes
let note = try await device.upload(contentsOf: file, toPath: "/NOTE/Note/Meeting.note")
print(note.id)                                                // the new file's identifier
try await device.withSyncLock { serverHasData in
    try await device.move(note.id, toPath: "/NOTE/Note/Archive/Meeting.note")
}
```

To-dos and digests, on the same session — what the tablet's to-do app and its digests keep:

```swift
let todo = SNTaskClient(session: session)
let list = try await todo.lists().first
var task = try await todo.create(SNTask(listID: list?.id, title: "Call the bank", due: tomorrow))
task.isCompleted = true
try await todo.update(task)                                   // the whole task: the service overwrites what is left out

let digests = SNDigestClient(session: session)
for group in try await digests.groups() {
    let passages = try await digests.digests(in: group.uniqueIdentifier)
    …
}
```

What changes elsewhere, as it changes — then REST for what it is:

```swift
for try await change in SNChangeFeed(session: session).changes() {
    switch change {
    case .connected: await reloadEverything()                 // initial connection or buffer overflow: refresh all
    case .files(let files): await reload(folders: files.compactMap(\.folderID))
    case .tasks: await reloadTasks()
    case .digests: await reloadDigests()
    }
}                                                           // ends with the connection: open it again
```

A private cloud:

```swift
let session = SNSession(endpoints: .privateCloud(URL(string: "http://nas.local:8080")!), secrets: keychain)
```

## Not here yet

- The to-do API's delta sync. Before service image 26.10.09 the server's filter for it was not limited to the account asking, and
  its rows carry nothing to sort another account's from one's own. That is fixed in 26.10.09, but a client cannot tell which server it is talking to, and a delta still never shows a deletion — so the listing
  stays whole.
- Uploads to Aliyun OSS (the China region's storage; currently unsupported), and resuming a
  multipart upload after a break.
- SMS verification. The email verification flow is implemented but has not been confirmed end to end.

## Building the framework

```sh
Scripts/build-xcframework.sh                                # -> build/SNCloud.xcframework
Scripts/fetch-redactlog.sh                                  # the RedactLog it links, into build/deps/
```

The same pipeline as `rmcloud-swift`: `project.yml` declares the sources once more as a framework target, XcodeGen generates the project, and
the script archives macOS, iOS and the simulator, checks each slice is dynamic and complete, and wraps them. A tag runs `.github/workflows/release.yml`.

## Checking against a real server

`snctl` is a command-line client for exactly that: `swift build --product snctl`, then `snctl login <account>` (the password is asked at the
terminal, or read from a `0600` file with `--password-file`; the access token, account and installation UUID are kept in a `0600` file per server under `~/.config/snctl`), and `snctl
check` — read-only — or `snctl check --write`, which uploads, downloads and deletes in a folder of its own, takes a file through the recycle bin
and back, and makes, changes and deletes a to-do list, a task and a digest tag; `--digests` adds a digest group and a digest, which the service
only marks deleted. Beyond `check`, a command per call: `ls`, `stat`, `get`, `put`, `mkdir`, `rm`, `mv`, `space` on the device API; `web-ls`,
`user`, `folders`, `bin`, `restore`, `purge`, `empty-bin`, `png` on the web API; `todo`, `digests`; `watch` for the change feed. `snctl -h` lists
them. `SNCLOUD_WIRE_LOG=headers|bodies` shows the exchange with every credential masked. `--private <url>` points it at a private cloud.

## Tests

`swift test` — the scripted transport and the in-memory store are in `Tests/SNCloudTests/Doubles.swift`, the scripted socket beside the change
feed's tests. The password digest, digest fingerprints and feed signature are checked against independently computed Python values.

## Trademark

Supernote is a trademark of Ratta Software. This project is not affiliated with, endorsed by or sponsored by Ratta Software.

## License

SNCloud is distributed under the [MIT License](LICENSE).
