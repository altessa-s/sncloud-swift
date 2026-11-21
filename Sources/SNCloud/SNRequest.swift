// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Where every request this client sends is born, and the protocol's own names
/// for the headers it carries.
///
/// The service this package speaks to is the one behind the web page at
/// `cloud.supernote.com`, and it is spoken to the way that page speaks: JSON
/// bodies, a token in `x-access-token`, an XSRF token beside it. Every client
/// this package was checked against names itself as a desktop browser, and none
/// of them reports a refusal for doing so — nobody has measured what the
/// service does with any other name, so this one does not try.
public enum SNRequest {
    /// The access token's header. Not `Authorization`: the service reads this
    /// one and no other.
    public static let accessTokenHeader = "x-access-token"

    /// The XSRF token's header, echoed from `GET /api/csrf`.
    public static let xsrfHeader = "X-XSRF-TOKEN"

    /// The cookie the service rotates the XSRF token through.
    static let xsrfCookie = "XSRF-TOKEN"

    /// The headers the official app sets on every call to its host, and the
    /// values it sets them to. See `SNDeviceIdentity` for the device's two.
    static let versionHeader = "version"
    static let protocolVersion = "202407"
    static let equipmentHeader = "equipmentNo"
    static let channelHeader = "channel"

    /// The language the official app names in its login and its code request.
    static let language = "EN"

    /// User-Agent for the app endpoints.
    static let appUserAgent = "Dart/3.8 (dart:io)"

    /// A request that already names this client. The token, the XSRF pair and
    /// the body are the caller's to add, because those differ per call.
    public static func to(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A JSON call, the shape of every call to `/api`: a POST almost always,
    /// and a GET, PUT or DELETE where the to-do and digest APIs ask for one.
    /// `body` is `nil` for a call that carries none — a GET, or a DELETE
    /// with the identifier in the path.
    static func json(_ url: URL, method: String = "POST", body: Data?) -> URLRequest {
        var request = to(url, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// The browser this client says it is to the web host, as the web page
    /// does. Public so a test can hold it against the wire.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/\(chromeVersion).0.0.0 Safari/537.36"

    static let chromeVersion = 142
}
