# Supernote Cloud interoperability notes

## Hosts and identity

Paths below are relative to `/api/`. The official service exposes two HTTP interfaces.
The same access token works with both.

| Interface | Host | Request headers |
|---|---|---|
| Browser file operations, bin and exports | `cloud.supernote.com` | Desktop Chrome User-Agent, XSRF header and cookies |
| Login, device sync, tasks and digests | `viewer.supernote.com` | `version: 202407`, `equipmentNo: <PLATFORM>_<uuid>`, `User-Agent: Dart/3.8 (dart:io)` |
| Private Cloud | Configured base URL for both interfaces | App headers on app calls. XSRF is optional. |

JSON requests use `Content-Type: application/json`. After login, the JWT travels in
`x-access-token`. On the web host, `GET csrf` supplies the `X-XSRF-TOKEN` response
header and its `XSRF-TOKEN` cookie. Send both, retain other cookies, and accept rotations
in `Set-Cookie`. On a 403 SNCloud renews the pair and retries once.

The installation keeps a lowercase UUID across logouts. The app header uses an underscore
and the device request body uses a hyphen, e.g. `MACOS-<uuid>`. A tablet may supply its
serial in the body, e.g. `SN000000000000`. Device sync, tasks, digests and storage
signature requests also send `channel: <token>_<PLATFORM><uuid>_<milliseconds>`.
The timestamp stays constant for the session's client instance. The feed uses the same identity.

## Responses

JSON payload fields sit beside `success`, `errorCode` and `errorMsg`. HTTP 200 can carry
a refusal. A 4xx envelope can carry a more specific service error. A 5xx remains a server
failure. Some compatible servers omit `success` on successful responses. Unknown service
errors retain their code and message.

| Code | Meaning | `SNError` |
|---|---|---|
| `E0712` | not logged in / session expired | `.sessionExpired` |
| `E0085` | invalid token | `.sessionExpired` |
| `E0019` | wrong password; locked after six | `.invalidCredentials` |
| `E0708`, `E0711` | wrong login or password | `.invalidCredentials` |
| `E0709`, `E0710`, `E0061` | disabled / locked / deleted | `.accountLocked` |
| `E1760` | an emailed code is required | `.verificationRequired` |
| `E1756`, `E0101` | code wrong or expired | `.invalidVerificationCode` |
| `E0322` | name already taken | `.alreadyExists` |
| `E0081`, `E0308`, `E0318`, `E0320`, `E0321` | no such file or path | `.notFound` |
| `E0068` | more than 1000 in a copy | `.rejected` |
| `E0078`, `E0079` | another device holds the sync lock | `.syncLocked` |
| `E0324` | file not accepted on `finish` (md5/size) | `.rejected` |
| no code | "Sorting condition cannot be empty" — `order`/`sequence` missing | `.rejected` |

File identifiers are 64-bit integers. Web requests use decimal strings. Responses may
contain either representation, so decoding through floating point can lose digits.
The root identifier is zero. Flags commonly use `"Y"` and `"N"`. Numeric times are
milliseconds since the Unix epoch unless specified otherwise.

## Login

1. POST `official/user/query/random/code` with `account` and `countryCode` (null for email).
   Keep `randomCode` and echo the returned `timestamp` with its original JSON type.
2. Compute lowercase hex MD5 of the UTF-8 password, concatenate that hex string with
   `randomCode`, then SHA-256 the UTF-8 result and encode it in lowercase hex.
3. POST `official/user/account/login/new` with the account, digest as `password`, timestamp,
   country code, `equipment: 2`, `loginMethod: 2` for email or `1` for phone,
   `language: "EN"`, the uppercase platform in `devices`, and explicit nulls for
   `equipmentNo` and `browser`. The salt is single-use. A failed exchange requires a new salt.
4. On `E1760`, POST `user/mail/validcode` with email and language for a `validCodeKey`.
   POST `user/check/validcode` with the code and key, then `user/sms/login` with
   `countryCode`, `equipment`, `telephone`, `validCode`, `validCodeKey`, `devices` and
   `email`. Despite its path, the final call also handles email. The code allows five
   attempts within five minutes.

A successful login returns `token`. The official cloud token normally lasts 30 days.
The JWT's `exp` usually counts seconds, but SNCloud also accepts milliseconds. Expiry
requires a new login. The client discards the token used by a request on HTTP 401,
`E0712` or `E0085`.

## Web files

These routes use POST. Web root folders include `Note`, `Document`, `Screenshot`,
`Inbox`, `Export` and `MyStyle`.

| Call | Request | Response |
|---|---|---|
| `file/list/query` | `directoryId`, `order` (`filename`/`time`/`size`), `sequence` (`asc`/`desc`), `pageNo` (from 1), `pageSize` | `total`, `pages`, `userFileVOList` |
| `file/list/search` | `fileName`, `order`, `sequence`, `pageNo`, `pageSize` | `total`, `userFileSearchVOList` (+ `directoryName`) |
| `file/folder/add` | `fileName`, `directoryId` | envelope only — **no id** |
| `file/delete` | `idList`, `directoryId` (parent) | envelope; to the trash |
| `file/move` | `idList`, `directoryId` (from), `goDirectoryId` (to) | envelope |
| `file/copy` | as `move` | envelope; at most 1000 |
| `file/rename` | `id`, `newName` | envelope |
| `file/capacity/query` | `{}` | `usedCapacity`, `totalCapacity` |
| `file/path/query` | `id` | `path: "Note/X/"`, `idPath: "12/34/"` |
| `user/query` | `{}` | `userId`, `userName`, `email`, `telephone`, `countryCode`, `avatarsUrl`, … |
| `file/download/url` | `id`, `type: 0` | `url` (signed), `md5` |
| `file/note/to/pdf` | `id`, `pageNoList: []` (= all), `type: 0` | `url`. Conversion takes minutes; an explicit page list that does not match the note gives "The QT program failed to parse the file!" |

File entries include `id`, `directoryId`, `fileName`, `size`, `md5`, `innerName`,
`isFolder`, `createTime` and `updateTime`.

## Device files

All routes use POST with `equipmentNo` in the body. File IDs are strings in requests
except for the numeric folder ID in `list_folder_v3`.

| Call | Request | Response |
|---|---|---|
| `file/2/files/list_folder` | `path` (`/` is the root), `recursive` | `entries: [EntriesVO]`; with `recursive: true` the whole tree as a flat list. UltraBridge reads only `id` from this call and returns the root for any `path` — list by `id` on UltraBridge |
| `file/3/files/list_folder_v3` | `id` — **a number**, `recursive` | same |
| `file/3/files/query_v3` | `id` (**a string**) | `entriesVO`, or `null` if absent |
| `file/3/files/query/by/path_v3` | `path` | `entriesVO` or `null` |
| `file/2/files/create_folder_v2` | `path` (full), `autorename: false` | `metadata: {tag, id, name, path_display}` — **with id** |
| `file/3/files/delete_folder_v3` | `id` | `metadata` |
| `file/3/files/move_v3` | `id`, `to_path` — **the full destination path including the name**, `autorename` | `entriesVO`. Renaming is the same call |
| `file/3/files/copy_v3` | as `move_v3` | `entriesVO` |
| `file/3/files/download_v3` | `id` | `url`, `name`, `path_display`, `content_hash`, `size`, `is_downloadable` |
| `file/3/files/upload/apply` | `path` (parent folder, e.g. `EXPORT/`), `fileName`; `size` **as a number** | upload slot (see below) |
| `file/2/files/upload/finish` | `path` — **the parent folder with a trailing slash**, `fileName`, `content_hash`, `innerName`, `size` — a number | `{path_display, id, size, name, content_hash}` — **with id** |
| `file/2/users/get_space_usage` | — | `used`, `allocationVO: {tag, allocated}` |
| `file/2/files/synchronous/start` | — | `synType`: `false` — the server is empty |
| `file/2/files/synchronous/end` | `flag`: `"Y"` / `"N"` | — |

Recursive listings are flat. `tag` distinguishes a file from a folder. The official service
can return the containing folder as `path_display`, including an empty string at root.
Downloads and some private servers return the full path. When listing a known folder, use the requested path to
disambiguate a file named like its parent. Entries can use either `_downloadable` or
`is_downloadable`. Device paths such as `NOTE/Note` and `DOCUMENT/Document` correspond
to web folders with the same IDs. Repeated slashes can occur.

A scoped sync starts with `synchronous/start`. A competing device may receive `E0078`.
The official service can omit `synType`. End with flag `Y` on success or `N` on failure.
SNCloud refuses overlapping scopes for one session and equipment number.

## Transfers

Web uploads start at `file/upload/apply` with `directoryId`, `fileName`, `md5` and
`size`. Device uploads send the parent folder with a trailing slash and no leading slash
in both apply and finish. Size is a JSON number. The slot's `apiServer` selects S3
(`1`), private form upload (`private_cloud`) or Aliyun OSS (`0`, unsupported).
Older slots omit the selector. A signed object URL indicates S3, a `fullUploadUrl` a form.
`fileServer` is an opaque value forwarded to the signing endpoint.

* **S3 through 8 MiB.** PUT the raw bytes to `url` with `Authorization` from
  `s3Authorization`, `x-amz-date` from `xamzDate`, `Content-Length`, and
  `x-amz-content-sha256: UNSIGNED-PAYLOAD`.
* **Larger S3 objects.** Request each signature at `file/s3/auth` with `fileServer`,
  `method`, query `params`, `awsHeaders: {}` and `uri` (the object key). Initiate
  with POST and `uploads`, read the XML `UploadId`, then PUT 8 MiB parts in order with
  `partNumber` and `uploadId`. Keep each ETag. Sign the completion POST with `uploadId`
  and `data` equal to the exact XML body. Its root is `CompleteMultipartUpload` with one
  `Part` containing `PartNumber` and `ETag` per part. A 200 can contain an XML error.
  Storage requests never receive the cloud token.
* **Private Cloud.** POST a multipart form with field `file` to `fullUploadUrl`, or send
  8 MiB parts to `partUploadUrl` with `uploadId`, `partNumber` and `totalChunks`.
  Check returned `chunkMd5` or whole-file MD5 when supplied. Resolve service storage
  routes on the configured origin before attaching the token.
* **Finish.** Web `file/upload/finish` takes `directoryId`, `fileName`, `fileSize`,
  `md5`, `innerName` and `type: "2"`. Device finish takes the parent path, name, size,
  `content_hash` and `innerName`. Use the S3 object key or the form slot's inner name.

Download the signed URL and validate size and MD5. An expired URL can return an XML body
with HTTP 200. A byte-range request requires HTTP 206 and a matching `Content-Range` and
body length. A shorter final range is valid at end of file.

## Tasks and lists

Task and digest routes below are relative to `/api/file/` on the app host. Both use the
flat JSON envelope. Validation errors may use `400`, type errors `422`, and an unknown
ID may yield `500`. Schedule requests require an account with an email or phone (`E0109`).

| Call | Request | Response |
|---|---|---|
| `POST schedule/group/all` | `maxResults` (**string**, default 20), `pageToken` (**string page number**, from 1) | `pageToken` (next page or `null`), `scheduleTaskGroup[]` |
| `GET schedule/group/{taskListId}` | — | `taskListId`, `title`, `lastModified`, `isDeleted`, `createTime`, `userId` |
| `POST schedule/group` | `taskListId?`, `title`, `lastModified`, `createTime` | `taskListId` |
| `PUT schedule/group` | `taskListId`, `title`, `lastModified` | envelope |
| `DELETE schedule/group/{taskListId}` | — | envelope |
| `POST schedule/task/all` | `maxResults` (string), **`nextPageTokens`** (plural, string page), `nextSyncToken` (ms) | `nextPageToken` (singular), `nextSyncToken`, `scheduleTask[]` |
| `POST schedule/task` | the task; `title` required | `taskId` |
| `PUT schedule/task` | the task; `taskId`, `title`, `lastModified` required | envelope (`taskId: null`) |
| `PUT schedule/task/list` | `taskListId`, `updateScheduleTaskList[]` | envelope |
| `DELETE schedule/task/{taskId}` | — | envelope |

Task rows include `taskId`, `taskListId`, `title`, `detail`, `status` (`needsAction`
or `completed`), `dueTime`, `completedTime`, `lastModified`, `recurrence` (RFC 5545),
`isReminderOn`, `importance`, `links`, `isDeleted` and ordering fields. The service
spells `planerSort` and `planerSortTime` with one n. Zero time means unset. Links encode
JSON in base64. The listing includes recurring occurrences in `scheduleRecurTask` with
their own task IDs and a `recurrenceId` naming the parent. Occurrences are read-only.

List and task IDs are strings. The default list is `"1"`. Generated IDs use MD5 of title
and last modification time. Collisions may append zeroes. Send the entire task on update
because omitted fields can be cleared. Batch updates may apply earlier items before an
error. Deleting a task removes it, and deleting a list removes its tasks. Delta listings
omit hard deletions and older Private Cloud versions can return rows outside the account.
SNCloud reads all pages. Missing groups and tasks use `E0328` and `E0329`; an expired
sync token uses `E0330` and a duplicate sort record uses `E0331`.

## Digests

Groups and digests share a response shape distinguished by `isSummaryGroup`. Their
row IDs are 64-bit JSON numbers. A digest links to a group by its `uniqueIdentifier`.

| Call | Request | Response |
|---|---|---|
| `POST query/summary/group` | `page`, `size` — both required (a null is `"500"`) | `totalRecords`, `totalPages`, `currentPage`, `pageSize`, `summaryDOList[]` |
| `POST add/summary/group` | `uniqueIdentifier`, `name`, `md5Hash` (required), `description`, `creationTime`, `lastModifiedTime` | `id` |
| `PUT update/summary/group` | `id`, `md5Hash` (required), `name`, `description`, `metadata`, … | envelope |
| `DELETE delete/summary/group` | **JSON body** `{id}` | envelope |
| `POST query/summary` | `page`, `size`, `parentUniqueIdentifier?`, `ids?` | as for groups |
| `POST query/summary/id` | `ids[]` | `summaryDOList[]` |
| `POST query/summary/hash` | as `query/summary` | paging + `summaryInfoVOList[]`: `id`, `md5Hash`, **`handwriteMd5`**, `commentHandwriteName`, `lastModifiedTime`, `metadataMap.author` |
| `POST add/summary` | `uniqueIdentifier`, `fileId`, `parentUniqueIdentifier`, `content`, `dataSource`, `sourcePath`, `sourceType`, `tags`, `md5Hash`, `metadata`, `commentStr`, `commentHandwriteName`, `handwriteInnerName`, **`handwriteMD5`**, `creationTime`, `lastModifiedTime`, `author` | `id` |
| `PUT update/summary` | `id` + the same, selective (null = unchanged) | envelope |
| `DELETE delete/summary` | JSON body `{id}` | envelope |
| `GET query/summary/tag` | — | `summaryTagDOList[]`: `id`, `name`, `userId`, `createdAt` |
| `POST add/summary/tag` | `name` | `id` |
| `PUT update/summary/tag` | `id`, `name` | envelope |
| `DELETE delete/summary/tag` | JSON body `{id}` | envelope |
| `POST download/summary` | `id` | `url` of the handwritten comment's file |
| `POST upload/apply/summary` | `fileName`, `equipmentNo` | `fullUploadUrl`, `partUploadUrl`, `innerName` |

Digest and group deletes mark the row deleted. Group deletion leaves the group's digests
intact. Tag deletion removes the tag. Tags are comma-separated text. Metadata contains
JSON encoded as a string. Service creation and update dates can be ISO strings or epoch
milliseconds. Other times use milliseconds.

Group fingerprints are lowercase MD5 of the concatenated UTF-8 identifier and name.
Digest fingerprints use the following fields in order, without separators. An absent
field contributes an empty string. Use decimal text for the source type and the exact
stored JSON text for metadata.

```text
content + parentUniqueIdentifier + sourceType + sourcePath + metadata + commentStr + commentHandwriteName
```

New identifiers are 32 lowercase hex digits. A group carries its identifier in the column.
A digest may leave the column null and carry `unique_identifier` inside metadata.
Metadata also holds the author, and may include `source_size` and `document_location_data`
for a book excerpt. A typed digest defaults to source type 4 and empty group, source path
and comments. Book excerpts can use source type 1. Changing the author, group or any
other fingerprint input requires recomputing the hash with the existing fields.

Handwriting apply can return an S3 slot with `s3Url`, signature, date and a
service-selected `innerName`, or a private form URL. Store the display name in
`commentHandwriteName`, storage name in `handwriteInnerName`, and MD5 in `handwriteMD5`.
The hash-list response spells the latter `handwriteMd5`. Verify the downloaded bytes
against the declared hash. Duplicate tag names or identifiers can return `E0335`,
`E0337` or `E0338`. Missing tags, groups and digests use `E0336`, `E0339` and `E0340`.

## Recycle bin, folder picker and exports

These web routes use POST with XSRF.

| Call | Request | Response |
|---|---|---|
| `file/recycle/list/query` | `order` (`filename`/`time`/`size`), `sequence`, `pageNo`, `pageSize` — all required | `total`, `recycleFileVOList[]`: `fileId` (string), `isFolder`, `fileName`, `size`, `updateTime` |
| `file/recycle/revert` | `idList` (not empty) | envelope |
| `file/recycle/delete` | `idList` (not empty) | envelope — for good |
| `file/recycle/clear` | `{}` | envelope — everything, for good |
| `file/folder/list/query` | `directoryId`, `idList` — **not empty** | `folderVOList[]`: `id`, `directoryId`, `fileName`, `empty` |
| `file/note/to/png` | `id`, `host?` | `pngPageVOList[]`: `pageNo`, `url` |

Web deletion moves entries into the bin. Device deletion is permanent. Restore keeps
the original IDs and can restore missing ancestors. Deduplicate IDs before sending a bin
request. A missing ID fails the request with `E0311`; a conflicting sync gives `E0301`.
Bin timestamps accept ISO strings or milliseconds. The folder picker requires a nonempty
exclusion list. SNCloud sends the parent ID when there are no selected entries.
`empty: "Y"` means the folder has no child folders.

PNG export returns one link per page. Results may be cached. `E0315` means the input
is not a note, `E0314` signals a conversion error, and `E0316` means conversion is
in progress. SNCloud retries the latter every five seconds for up to five minutes.
The optional `host` affects converter access and returned links. SNCloud omits it,
routes private storage links to the configured server, and checks the PNG signature.

## Change feed

Connect to `wss://app-wss-file.supernote.com/socket.io/` or the private server's
`/socket.io/` over WS or WSS as appropriate. Use socket.io 2 over Engine.IO 3 with
`EIO=3`, `transport=websocket`, `token`, `type`, `random` and `sign`.
The type and random value match the installation and timestamp in the channel header.
Sign the UTF-8 bytes of `token_type_random` with HMAC-SHA256 using the literal UTF-8
key `K+5xFzxbnB1iSZWqmu3Etw==`. Base64-encode the MAC and retain only ASCII
letters and digits. Rejection can arrive as a `ServerMessage` with code `403` before disconnect.

The Engine.IO open packet supplies the heartbeat interval and timeout. On connection
send `ratta_ping`, then repeat it alongside Engine.IO ping at the advertised interval.
Each event has one string argument encoding a JSON envelope with `code`, `msg`,
`timestamp`, `msgType` and a `data` array. Acknowledge on the same event with
`"Received"`.

| Event | `msgType` | `data[]` | `messageType` |
|---|---|---|---|
| `ServerMessage` | `FILE-SYN` | `messageType, equipmentNo, fileType (FILE/FOLDE), id, newId, originalName, newName, md5, size, directoryId, goDirectoryId, originalPath, newPath, timestamp` | `DOWNLOADFILE` (added), `ADDFOLDER`, `MODIFYFILE`, `MODIFYFOLDER`, `DELETEFILE`, `DELETEFOLDER`, `COPYFILE`, `COPYFOLDER`, `MOVEFILE`, `MOVEFOLDER`, `WAITING`, `STARTSYNC` |
| `to-do` | `TASK-SYN` | `messageType, equipmentNo, taskListId, taskId, timestamp` | `QUERY` (something changed), `SORT` |
| `digest` | `DIGEST-SYN` | `messageType, dataType` (`1` group, `2` digest, `3` tag), `id`, the digest's fields, `timestamp` | `ADD_DIGEST`, `UPDATE_DIGEST`, `DELETE_DIGEST` |

Queues are per connection and expire after ten minutes. Requests whose channel matches
the connection's type suppress self-notifications. Web requests omit that channel.
Disconnects lose pending events. Refresh from REST on each `.connected`, including the
refresh signal emitted when the 256-event buffer overflows. A connection without an
Engine.IO open frame times out after 30 seconds.
