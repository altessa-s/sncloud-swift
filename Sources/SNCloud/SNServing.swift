// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The account as everything above the protocol sees it: logged in or not, a
/// login to make, a code to confirm it, a way out.
///
/// The access token never appears here. It is the one thing that must not
/// travel past `SNCloud`, and a port that offered it would be an invitation to
/// carry one into a view model.
public protocol SNAccountServing: Sendable {
    var isLoggedIn: Bool { get async throws }
    var account: String? { get async throws }
    func logIn(account: String, password: String, countryCode: Int?) async throws -> SNLoginOutcome
    func sendVerificationCode() async throws
    func verify(code: String) async throws
    func logOut() async throws
}

public extension SNAccountServing {
    func logIn(account: String, password: String) async throws -> SNLoginOutcome {
        try await logIn(account: account, password: password, countryCode: nil)
    }
}

extension SNSession: SNAccountServing {}

/// The cloud as a library talks to it. The production client is an actor with
/// a session and retries behind it; tests and a composition root pass this port
/// so the packages above do not have to name that actor.
public protocol SNFileServing: Sendable {
    func list(_ folder: SNFileID, order: SNSortOrder, ascending: Bool) async throws -> [SNEntry]
    func search(_ name: String, order: SNSortOrder, ascending: Bool) async throws -> [SNEntry]
    func entry(named name: String, in folder: SNFileID) async throws -> SNEntry?
    func createFolder(named name: String, in parent: SNFileID) async throws -> SNEntry
    func delete(_ ids: [SNFileID], from parent: SNFileID) async throws
    func move(_ ids: [SNFileID], from parent: SNFileID, to destination: SNFileID) async throws
    func copy(_ ids: [SNFileID], from parent: SNFileID, to destination: SNFileID) async throws
    func rename(_ id: SNFileID, to name: String) async throws
    func capacity() async throws -> SNCapacity
    func user() async throws -> SNUser
    func location(of id: SNFileID) async throws -> SNLocation
    func download(_ id: SNFileID, expecting size: Int64?, onProgress: @escaping TransferProgress) async throws -> URL
    func pdf(ofNote id: SNFileID, pages: [Int], onProgress: @escaping TransferProgress) async throws -> URL
    func upload(
        contentsOf file: URL,
        named name: String?,
        to folder: SNFileID,
        onProgress: @escaping TransferProgress
    ) async throws
}

public extension SNFileServing {
    func list(_ folder: SNFileID = .root) async throws -> [SNEntry] {
        try await list(folder, order: .name, ascending: true)
    }

    func download(_ id: SNFileID) async throws -> URL {
        try await download(id, expecting: nil, onProgress: { _, _ in })
    }

    func upload(contentsOf file: URL, to folder: SNFileID = .root) async throws {
        try await upload(contentsOf: file, named: nil, to: folder, onProgress: { _, _ in })
    }
}

extension SNClient: SNFileServing {}

/// The cloud by path, as the device API serves it. A port of its own rather
/// than more of `SNFileServing`: the two APIs name the same tree differently,
/// and a caller that holds one kind of name should not be handed the other.
public protocol SNDeviceFileServing: Sendable {
    var equipmentNo: String { get async throws }
    func list(path: String, recursive: Bool) async throws -> [SNDeviceEntry]
    func list(folder: SNFileID, recursive: Bool) async throws -> [SNDeviceEntry]
    func entry(_ id: SNFileID) async throws -> SNDeviceEntry?
    func entry(atPath path: String) async throws -> SNDeviceEntry?
    func spaceUsage() async throws -> SNSpaceUsage
    func createFolder(atPath path: String, autorename: Bool) async throws -> SNDeviceEntry
    func delete(_ id: SNFileID) async throws
    func move(_ id: SNFileID, toPath path: String, autorename: Bool) async throws -> SNDeviceEntry?
    func copy(_ id: SNFileID, toPath path: String, autorename: Bool) async throws -> SNDeviceEntry?
    func download(_ id: SNFileID, range: ClosedRange<Int64>?, onProgress: @escaping TransferProgress) async throws -> URL
    func upload(contentsOf file: URL, toPath path: String, onProgress: @escaping TransferProgress) async throws -> SNDeviceEntry
    func withSyncLock<T: Sendable>(_ body: @Sendable (_ serverHasData: Bool) async throws -> T) async throws -> T
}

extension SNDeviceClient: SNDeviceFileServing {}
