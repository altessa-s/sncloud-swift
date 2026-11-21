// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// Each raw value below is a Keychain account name on people's machines, not a
// by-product of a case name. Spelled out so that renaming a case cannot silently
// become a change of account. `ConfigurationTests` pins both.
// swiftlint:disable redundant_string_enum_value

/// What this protocol keeps between launches, and nothing else.
///
/// **The password is not among them.** It is asked for, digested with a
/// one-time salt and forgotten in the same call. The cost is that a session the
/// service ends — after thirty days, or sooner — takes the password again; the
/// service offers no refresh, so the only alternative would be holding the
/// password itself, and that is a trade this package does not make for a host.
///
/// Frozen, for the reason given on `SNError`.
@frozen
public enum SNSecret: String, Sendable, CaseIterable {
    /// The access token: a JWT the service issued at login, sent as
    /// `x-access-token` on every call.
    case accessToken = "accessToken"
    /// The account the token belongs to — an email address or a phone number —
    /// kept so that a host can say who is logged in and offer it back at the
    /// next login.
    case account = "account"
    /// The installation's own identifier: a UUID made once and kept, as the
    /// official client keeps its `client_id`. It is what the service knows this
    /// machine by — `equipmentNo` and the `channel` header are built from it —
    /// so it outlives a logout: a new one on every login would look to the
    /// account like a new device every time.
    case clientID = "clientID"
}

// Equality spelled out rather than synthesised; see `SNError`.
extension SNSecret {
    public static func == (lhs: SNSecret, rhs: SNSecret) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

/// Where the secrets live. A port, not a store: this package does not know what
/// a Keychain is. Whatever a host already keeps secrets in conforms to this as
/// well.
///
/// The selectors are distinct from `RMCloud`'s on purpose: a store that answers
/// both protocols would otherwise have two overloads of each, and a leading dot
/// could be either vocabulary's.
public protocol SNSecretStoring: Sendable {
    func secret(_ which: SNSecret) throws -> String?
    func keep(_ value: String, as which: SNSecret) throws
    func discard(_ which: SNSecret) throws
}
// swiftlint:enable redundant_string_enum_value
