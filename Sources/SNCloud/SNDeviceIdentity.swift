// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Who this installation is to the service, spelled the way the official
/// client spells itself.
///
/// The service identifies an installation by its uppercase platform and persistent UUID:
///
/// ```
/// equipmentNo header   MACOS_<uuid>          (an underscore)
/// equipmentNo in a body MACOS-<uuid>         (a hyphen)
/// channel header       <token>_MACOS<uuid>_<milliseconds>
/// ```
///
/// The two separators are not a typo here: the client builds the header and
/// the body in two places, and every request on the wire carries both forms.
public struct SNDeviceIdentity: Sendable, Equatable {
    /// `MACOS`, `IOS`, `ANDROID`, … — the operating system's name in capitals.
    public let platform: String
    /// The UUID, lowercase, as the official client stores it.
    public let clientID: String

    public init(platform: String = SNDeviceIdentity.currentPlatform, clientID: String) {
        self.platform = platform
        self.clientID = clientID.lowercased()
    }

    /// What goes in a body's `equipmentNo`.
    public var equipmentNo: String { "\(platform)-\(clientID)" }

    /// What goes in the `equipmentNo` header.
    public var equipmentHeader: String { "\(platform)_\(clientID)" }

    /// The `channel` header: the token, the platform and the UUID run
    /// together, and a number fixed for the life of the process.
    ///
    /// The official client takes the number once per process — milliseconds
    /// since the epoch — and caches the whole string, token included, on first
    /// use. This builds it with the token of the call instead: a string that
    /// names a token the service has stopped accepting helps nobody.
    func channel(token: String, started: String) -> String {
        "\(token)_\(socketType)_\(started)"
    }

    /// The middle of `channel`, and the `type` the socket.io channel is opened
    /// with: the service leaves a change out of the announcements to every
    /// connection of the `type` that made it, so the two have to agree.
    var socketType: String { "\(platform)\(clientID)" }

    /// The name of the system this build runs on, as Dart's
    /// `Platform.operatingSystem.toUpperCase()` would have it.
    public static var currentPlatform: String {
        #if os(macOS)
        "MACOS"
        #elseif os(iOS)
        "IOS"
        #else
        "UNKNOWN"
        #endif
    }
}
