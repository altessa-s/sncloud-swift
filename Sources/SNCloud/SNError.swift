// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The protocol's errors. HTTP statuses, the envelope's error codes and network
/// failures become these before they leave the package, so the UI never takes
/// the wire apart. Cancellation is the exception: `URLError.cancelled` is
/// rethrown unchanged (see `transportFailure`).
///
/// Frozen, for the reason `RMCloud` gives on its own: this framework ships in
/// lockstep with whatever links it, so there is no ABI to protect — and the one
/// place that turns these into a sentence for a person must break its build
/// when a case is added, not fall into an `@unknown default`.
///
/// **Most refusals arrive as HTTP 200.** The service wraps every answer in
/// `{"success", "errorCode", "errorMsg"}`, and a wrong password, an expired
/// session and a missing file all come back with a 200 status and
/// `success: false`. The codes below are read from that envelope; see
/// `fromEnvelope`.
@frozen
public enum SNError: Error, Sendable, Equatable {
    /// There is no access token: nobody has logged in, or the session was
    /// forgotten.
    case notLoggedIn
    /// The service no longer accepts the access token: `E0712` ("not logged
    /// in"), `E0085` ("token invalid") or a 401.
    ///
    /// There is no refresh: a web token lives thirty days and the only way to
    /// another one is to log in again, password and all. The token is dropped
    /// from the store before this is thrown.
    case sessionExpired
    /// The account or the password is wrong: `E0019`, `E0708`, `E0711`.
    case invalidCredentials
    /// The account is disabled, locked after too many attempts, or cancelled:
    /// `E0709`, `E0710`, `E0061`. The code is kept: the three mean different
    /// things to the person who owns the account.
    case accountLocked(code: String)
    /// The service wants the login confirmed with a code sent to the account's
    /// email: `E1760`. `SNSession.logIn` answers this as an outcome rather than
    /// throwing it; it is a case here for a call that meets it anywhere else.
    case verificationRequired
    /// The emailed code is wrong or expired: `E1756`, `E0101`. A code lives five
    /// minutes and allows five attempts; past that the login starts over.
    case invalidVerificationCode
    /// `verify(code:)` was called with no login waiting for a code.
    case noVerificationPending
    /// Something with that name is already where it was asked to go: `E0322`;
    /// a digest tag's name or a digest group's identifier already taken:
    /// `E0335`, `E0337`, `E0338`.
    case alreadyExists
    /// The file or folder the request named is not there: `E0081`, `E0308`,
    /// `E0318`, `E0320`, `E0321`; or no longer in the recycle bin: `E0311`. Or the to-do list, the task, the digest group,
    /// the digest or the tag: `E0328`, `E0329`, `E0339`, `E0340`, `E0336`.
    case notFound(code: String)
    /// Another device holds the account's sync lock: `E0078`, `E0079`, and
    /// `E0301` from a restore out of the recycle bin. Only the device API's
    /// `synchronous/start` takes it; the lock lapses on its own if its holder
    /// never lets go.
    case syncLocked
    /// Any other refusal in the envelope, with the service's own words.
    case rejected(code: String, message: String)
    /// The response does not have the expected shape.
    case malformedResponse(String)
    /// Bytes whose MD5 disagrees with the one the service declared. A signed
    /// storage URL that has expired is known to answer 200 with an XML error
    /// document, and this is how that is caught.
    case checksumMismatch(expected: String, actual: String)
    /// Too many requests.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other unsuccessful HTTP status. The path is kept for diagnostics:
    /// unlike the headers and the query, it holds no secrets.
    case http(status: Int, path: String)
    /// A network error. The `URLError` code is kept rather than a description
    /// with the URL: a signed URL's query is a credential.
    case transport(code: Int)
    /// A response too large to be one of the protocol's own JSON answers.
    case oversizedResponse(bytes: Int, limit: Int)
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness the
// compiler derives — and that witness is internal, so it is absent from this
// module's symbol table when SNCloud is linked as a binary framework. A concrete
// comparison resolves in a release build, where it is inlined, and fails to link
// in a debug one. Declaring `==` here puts it behind an exported symbol.
extension SNError {
    public static func == (lhs: SNError, rhs: SNError) -> Bool {
        switch (lhs, rhs) {
        case (.notLoggedIn, .notLoggedIn),
             (.sessionExpired, .sessionExpired),
             (.invalidCredentials, .invalidCredentials),
             (.verificationRequired, .verificationRequired),
             (.invalidVerificationCode, .invalidVerificationCode),
             (.noVerificationPending, .noVerificationPending),
             (.alreadyExists, .alreadyExists),
             (.syncLocked, .syncLocked):
            true
        case let (.accountLocked(left), .accountLocked(right)): left == right
        case let (.notFound(left), .notFound(right)): left == right
        case let (.rejected(leftCode, leftMessage), .rejected(rightCode, rightMessage)):
            leftCode == rightCode && leftMessage == rightMessage
        case let (.malformedResponse(left), .malformedResponse(right)): left == right
        case let (.checksumMismatch(leftExpected, leftActual), .checksumMismatch(rightExpected, rightActual)):
            leftExpected == rightExpected && leftActual == rightActual
        case let (.rateLimited(left), .rateLimited(right)): left == right
        case let (.http(leftStatus, leftPath), .http(rightStatus, rightPath)):
            leftStatus == rightStatus && leftPath == rightPath
        case let (.transport(left), .transport(right)): left == right
        case let (.oversizedResponse(leftBytes, leftLimit), .oversizedResponse(rightBytes, rightLimit)):
            leftBytes == rightBytes && leftLimit == rightLimit
        default: false
        }
    }
}

/// What a `URLSession` failure is in the protocol's terms — and the one that is
/// no failure at all: `-999` means the caller's own task was cancelled, and
/// carrying it outwards as `.transport` would turn the user's decision into
/// "the server is unreachable" and a retry nobody wants.
func transportFailure(_ error: URLError) -> any Error {
    error.code == .cancelled ? error : SNError.transport(code: error.errorCode)
}

public extension SNError {
    /// What an unsuccessful HTTP status means, or `nil` for a success.
    static func fromHTTP(_ response: HTTPURLResponse) -> SNError? {
        switch response.statusCode {
        case 200..<300:
            nil
        case 401:
            .sessionExpired
        case 429:
            .rateLimited(
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                    .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            )
        default:
            .http(status: response.statusCode, path: response.url?.path() ?? "")
        }
    }

    /// What a `success: false` envelope means.
    ///
    /// The codes are the ones the reference clients and the private-cloud
    /// re-implementations agree on; anything else is carried as `rejected`
    /// with the service's own sentence, because a code nobody has catalogued is
    /// still worth reading in a log.
    static func fromEnvelope(code: String?, message: String?) -> SNError {
        let code = code?.trimmingCharacters(in: .whitespaces) ?? ""
        let message = message ?? ""
        switch code {
        case "E0712", "E0085": return .sessionExpired
        case "E0019", "E0708", "E0711": return .invalidCredentials
        case "E0709", "E0710", "E0061": return .accountLocked(code: code)
        case "E1760": return .verificationRequired
        case "E1756", "E0101": return .invalidVerificationCode
        case "E0322", "E0335", "E0337", "E0338": return .alreadyExists
        case "E0081", "E0308", "E0311", "E0318", "E0320", "E0321": return .notFound(code: code)
        case "E0328", "E0329", "E0336", "E0339", "E0340": return .notFound(code: code)
        case "E0078", "E0079", "E0301": return .syncLocked
        default: return .rejected(code: code, message: message)
        }
    }

    /// Whether this says the access token is no good, so that the session
    /// should drop it.
    var meansSessionIsGone: Bool {
        if case .sessionExpired = self { return true }
        return false
    }
}
