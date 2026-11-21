// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// What happens to a redirect before this client follows it.
///
/// `URLSession` follows one on its own and only shows the delegate the request
/// it is about to send. Four headers must not go with it off the origin they
/// were meant for: the access token, the XSRF token and the cookies that pair
/// with it, and the S3 signature an upload carries in `Authorization`. The
/// access token is a thirty-day credential to the whole account, and a
/// redirect is the one route by which it can leave without anybody choosing to
/// send it.
///
/// So: the headers are dropped the moment the hop changes scheme, host or port,
/// and kept when it does not — a hop inside its own origin is still the same
/// conversation, and stripping it there would turn an ordinary redirect into a
/// refusal.
enum Redirects {
    /// The headers in question, spelled the way this package sets them.
    static let credentials = [
        SNRequest.accessTokenHeader,
        SNRequest.xsrfHeader,
        // Starts with the access token: see `SNDeviceIdentity.channel`.
        SNRequest.channelHeader,
        "Cookie",
        "Authorization",
    ]

    /// The redirect as it may be sent — the request the loading system built,
    /// minus the credentials when the hop leaves the origin it started from —
    /// or `nil` when it may not be followed at all.
    ///
    /// Two hops are refused outright, because stripping headers does not make
    /// them safe. One from HTTPS to plain HTTP sends whatever is left in the
    /// clear. One that leaves the origin with a body — a 307 or 308 keeps the
    /// method and the body — would carry the body there, and the bodies this
    /// client sends are a password digest, a pre-auth signature, an emailed
    /// code, or a file. Refused, the redirect's own answer comes back to the
    /// caller as the HTTP status it was.
    ///
    /// `previous` is where the redirecting answer came from. An origin nobody
    /// can name is not one we can call the same, so `nil` strips too.
    static func following(_ redirect: URLRequest, from previous: URL?) -> URLRequest? {
        if previous?.scheme?.lowercased() == "https", redirect.url?.scheme?.lowercased() != "https" {
            return nil
        }
        let staying = sameOrigin(previous, redirect.url)
        let method = redirect.httpMethod?.uppercased() ?? "GET"
        if !staying, !["GET", "HEAD"].contains(method) {
            return nil
        }
        let carried = credentials.filter { redirect.value(forHTTPHeaderField: $0) != nil }
        guard !carried.isEmpty, !staying else { return redirect }
        var stripped = redirect
        for field in carried {
            stripped.setValue(nil, forHTTPHeaderField: field)
        }
        return stripped
    }

    /// Whether two URLs are the same origin: scheme, host and port, with the
    /// scheme's default port standing in for one nobody wrote down. Case is
    /// folded on the scheme and the host, neither of which is case-sensitive.
    static func sameOrigin(_ one: URL?, _ other: URL?) -> Bool {
        guard let one, let other,
              let scheme = one.scheme?.lowercased(),
              let otherScheme = other.scheme?.lowercased(),
              let host = one.host()?.lowercased(),
              let otherHost = other.host()?.lowercased()
        else { return false }
        return scheme == otherScheme && host == otherHost && port(of: one) == port(of: other)
    }

    private static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// The whole of what every delegate in this package does with a redirect: write
/// it down, take the credentials off it when it leaves the origin, and let it
/// go. One function because there are three delegates, and three copies of a
/// rule about credentials is three places for it to stop being true.
func followRedirect(
    _ response: HTTPURLResponse,
    to request: URLRequest,
    on task: URLSessionTask
) -> URLRequest? {
    let previous = response.url ?? task.currentRequest?.url
    guard let following = Redirects.following(request, from: previous) else {
        Log.supernote.notice(
            "redirect to \(request.url?.host() ?? "elsewhere", .public) refused: it would leave the origin with a body, or leave HTTPS"
        )
        SNWireLog.redirected(from: response, to: request)
        return nil
    }
    if following.allHTTPHeaderFields?.count != request.allHTTPHeaderFields?.count {
        Log.supernote.debug(
            "redirect leaves the origin: credentials are not carried to \(following.url?.host() ?? "elsewhere", .public)"
        )
    }
    SNWireLog.redirected(from: response, to: following)
    return following
}
