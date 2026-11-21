// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// The protocol of the Supernote cloud, and nothing else: the login, the token,
// the file tree, the transfers, the retry policy. Unofficial and
// reverse-engineered — which is exactly why it is worth having behind a wall of
// its own.
//
// One dependency, and it is not a layer: `RedactLog`, for the lines this
// package writes. Everything else it needs from a host arrives as a port — the account's
// secrets through `SNSecretStoring`, progress as a closure — and everything it
// answers with is its own: `SNEntry`, `SNUser`, `SNCapacity`, `SNError`. It
// knows of no application, no file system and no window.
import PackageDescription

let package = Package(
    name: "SNCloud",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SNCloud", targets: ["SNCloud"]),
        // A command-line client for checking the protocol against a real account.
        // A tool for whoever develops this package, not part of what a host links.
        .executable(name: "snctl", targets: ["snctl"]),
    ],
    // Pinned to a release tag, exactly, and the same one `rmcloud-swift` pins: a
    // logger is linked into every package of a host, and two of them built
    // against different versions is how a sink stops receiving lines. The
    // framework build links that same release's `.xcframework` —
    // `Scripts/RedactLog.pin` names it, and `Scripts/fetch-redactlog.sh` checks
    // the two pins agree.
    dependencies: [
        .package(url: "https://github.com/altessa-s/redactlog-swift.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "SNCloud",
            dependencies: [.product(name: "RedactLog", package: "redactlog-swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "snctl",
            dependencies: ["SNCloud", .product(name: "RedactLog", package: "redactlog-swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SNCloudTests",
            dependencies: [
                "SNCloud",
                // Named, and not left to arrive through `SNCloud`: a test that
                // says `import RedactLog` depends on it itself.
                .product(name: "RedactLog", package: "redactlog-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "snctlTests",
            dependencies: ["snctl", "SNCloud"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
