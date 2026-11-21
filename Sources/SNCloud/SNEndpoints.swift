// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// The only place the protocol's hosts and paths live in.
///
/// The official cloud is two hosts that share one account and one token. The
/// apps — Supernote Partner on every platform, both versions examined — speak
/// to `viewer.supernote.com`: the login, the device API, the uploads, with no
/// XSRF handshake. The web page speaks to `cloud.supernote.com`, which wants
/// the handshake and is the one that serves the paged listing by identifier.
/// `SNSession` and `SNDeviceClient` use the first, `SNClient` the second.
///
/// A private cloud — Ratta's self-hosted server, or a re-implementation — is
/// one host for both, at whatever address its owner gave it.
public struct SNEndpoints: Sendable, Equatable {
    /// Where the apps' `/api/…` is served: the login and the device API.
    public var appHost: URL
    /// Where the web page's `/api/…` is served: the listing by identifier.
    public var webHost: URL
    /// Whether calls to `webHost` carry the XSRF token from `GET /api/csrf`.
    ///
    /// The official web host refuses a call without one. The apps' host is not
    /// asked for it by the official client, and a private cloud is not known to
    /// ask for it either — so it is a property of the server, and of the web
    /// host only.
    public var webUsesXSRF: Bool
    /// Where the socket.io channel that announces changes is served, at
    /// `/socket.io/`. The official cloud keeps it on a host of its own; a
    /// private cloud serves it on its one host, behind the same proxy.
    public var socketHost: URL

    public init(appHost: URL, webHost: URL, webUsesXSRF: Bool, socketHost: URL? = nil) {
        self.appHost = appHost
        self.webHost = webHost
        self.webUsesXSRF = webUsesXSRF
        self.socketHost = socketHost ?? appHost
    }

    /// The official cloud.
    public static let official = SNEndpoints(
        appHost: URL.constant("https://viewer.supernote.com"),
        webHost: URL.constant("https://cloud.supernote.com"),
        webUsesXSRF: true,
        socketHost: URL.constant("https://app-wss-file.supernote.com")
    )

    /// The official cloud's China region, as the official client names it. Its
    /// web host is not named by any source, so the apps' one stands in for both.
    public static let officialChina = SNEndpoints(
        appHost: URL.constant("https://viewer.supernote.com.cn"),
        webHost: URL.constant("https://viewer.supernote.com.cn"),
        webUsesXSRF: false,
        socketHost: URL.constant("https://app-wss-file.supernote.com.cn")
    )

    /// A private cloud at `host` — `https://supernote.example.com`, or
    /// `http://192.168.1.10:8080` on a home network.
    ///
    /// Plain HTTP is accepted here, unlike in `fromEnvironment`: the owner of a
    /// private cloud chose the address, and on a home network HTTP is what such
    /// a server usually speaks. App Transport Security still has the last word
    /// inside an application.
    public static func privateCloud(_ host: URL, usesXSRF: Bool = false) -> SNEndpoints {
        SNEndpoints(appHost: host, webHost: host, webUsesXSRF: usesXSRF)
    }

    /// Overriding the hosts for debugging and for tests against a fake server.
    ///
    /// ```
    /// SNCLOUD_HOST    every host at once
    /// SNCLOUD_XSRF    off — skip the XSRF handshake on the web host (on by default)
    /// ```
    ///
    /// **Not for a shipped app.** Whoever picks the host receives the password
    /// digest and the access token, because the client carries them there
    /// itself — and an environment variable is picked by whoever last ran
    /// `launchctl setenv`, not by whoever signed the bundle. A host application
    /// calls this in a debug build only.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SNEndpoints {
        var endpoints = official
        if let host = override(environment["SNCLOUD_HOST"]) {
            endpoints.appHost = host
            endpoints.webHost = host
            endpoints.socketHost = host
        }
        if let xsrf = environment["SNCLOUD_XSRF"]?.lowercased(), ["off", "0", "false", "no"].contains(xsrf) {
            endpoints.webUsesXSRF = false
        }
        return endpoints
    }

    /// An override, taken only when it names somewhere a token may go: HTTPS
    /// anywhere, plain HTTP on the loopback, and nowhere else.
    private static func override(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased()
        else {
            Log.supernote.error("ignoring a host override that is not a URL")
            return nil
        }
        let loopback = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || (scheme == "http" && loopback.contains(host)) else {
            Log.supernote.error("ignoring host override \(host, .public): only HTTPS, or HTTP on the loopback")
            return nil
        }
        return url
    }

    // MARK: - Paths

    /// A path under `/api` on the apps' host, without the leading slash.
    public func app(_ path: String) -> URL {
        appHost.appending(path: "api/\(path)")
    }

    /// A path under `/api` on the web host, without the leading slash.
    public func web(_ path: String) -> URL {
        webHost.appending(path: "api/\(path)")
    }

    /// The XSRF handshake on the web host: a GET whose answer carries the
    /// token in a header.
    public var csrf: URL { web("csrf") }

    /// The page where an account is managed and a password reset. Not a
    /// protocol host: it is the website a host application may open.
    public static let accountPage = URL.constant("https://cloud.supernote.com")
}

/// The calls this package makes, by the service's own paths. Collected so that
/// a test, a wire log and a reader look in one place.
enum SNPath {
    static let randomCode = "official/user/query/random/code"
    static let login = "official/user/account/login/new"
    static let logout = "user/logout"
    static let user = "user/query"

    static let list = "file/list/query"
    static let search = "file/list/search"
    static let createFolder = "file/folder/add"
    static let delete = "file/delete"
    static let move = "file/move"
    static let copy = "file/copy"
    static let rename = "file/rename"
    static let capacity = "file/capacity/query"
    static let downloadURL = "file/download/url"
    static let path = "file/path/query"
    static let noteToPDF = "file/note/to/pdf"
    static let noteToPNG = "file/note/to/png"
    static let folders = "file/folder/list/query"
    static let recycleList = "file/recycle/list/query"
    static let recycleRestore = "file/recycle/revert"
    static let recycleDelete = "file/recycle/delete"
    static let recycleClear = "file/recycle/clear"
    static let uploadApply = "file/upload/apply"
    static let uploadFinish = "file/upload/finish"
    static let s3Auth = "file/s3/auth"
    static let mailCode = "user/mail/validcode"
    static let checkCode = "user/check/validcode"
    static let appCodeLogin = "user/sms/login"

    // The device API. The `2` and `3` are the server's own generations, and a
    // tablet mixes them in one sync: it lists on 2 and queries on 3, applies
    // for an upload on 3 and finishes it on 2.
    static let deviceSyncStart = "file/2/files/synchronous/start"
    static let deviceSyncEnd = "file/2/files/synchronous/end"
    static let deviceList = "file/2/files/list_folder"
    static let deviceListByID = "file/3/files/list_folder_v3"
    static let deviceQuery = "file/3/files/query_v3"
    static let deviceQueryByPath = "file/3/files/query/by/path_v3"
    static let deviceCreateFolder = "file/2/files/create_folder_v2"
    static let deviceDelete = "file/3/files/delete_folder_v3"
    static let deviceMove = "file/3/files/move_v3"
    static let deviceCopy = "file/3/files/copy_v3"
    static let deviceDownload = "file/3/files/download_v3"
    static let deviceUploadApply = "file/3/files/upload/apply"
    static let deviceUploadFinish = "file/2/files/upload/finish"
    static let deviceSpace = "file/2/users/get_space_usage"

    // The to-do API: lists ("groups") and tasks, by the paths the official app
    // names. REST in its methods — a GET, PUT and DELETE beside the POSTs —
    // and an identifier in the path where one entry is meant.
    static let taskLists = "file/schedule/group/all"
    static let taskList = "file/schedule/group"
    static let tasks = "file/schedule/task/all"
    static let task = "file/schedule/task"
    static let taskBatch = "file/schedule/task/list"

    // The digest API. The service calls a digest a summary and a group of
    // them a summary group; the paths are its own.
    static let digestGroups = "file/query/summary/group"
    static let digestGroupAdd = "file/add/summary/group"
    static let digestGroupUpdate = "file/update/summary/group"
    static let digestGroupDelete = "file/delete/summary/group"
    static let digests = "file/query/summary"
    static let digestsByID = "file/query/summary/id"
    static let digestHashes = "file/query/summary/hash"
    static let digestAdd = "file/add/summary"
    static let digestUpdate = "file/update/summary"
    static let digestDelete = "file/delete/summary"
    static let digestTags = "file/query/summary/tag"
    static let digestTagAdd = "file/add/summary/tag"
    static let digestTagUpdate = "file/update/summary/tag"
    static let digestTagDelete = "file/delete/summary/tag"
    static let digestHandwritingApply = "file/upload/apply/summary"
    static let digestHandwriting = "file/download/summary"
}

/// A URL decided when the code was written. A named function rather than `!`
/// at each site, so that the force-unwrap can be forbidden everywhere else.
private extension URL {
    static func constant(
        _ text: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> URL {
        guard let url = URL(string: text) else {
            preconditionFailure("not a URL: \(text)", file: file, line: line)
        }
        return url
    }
}
