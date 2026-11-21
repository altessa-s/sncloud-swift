// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import SNCloud

/// `snctl check`: the calls this package makes, against a real account, one
/// line each, carrying on past a failure so that one run shows everything.
///
/// Read-only unless `--write` is given. With it, everything written goes into a
/// folder of its own under `/INBOX`, named for the time, and is deleted at the
/// end — a failure in the middle can leave it behind, and the last lines say so.
struct Check {
    let commands: Commands
    let write: Bool
    var digests = false

    var device: SNDeviceClient { commands.device }
    var web: SNClient { commands.web }
    var todo: SNTaskClient { commands.todo }
    var digest: SNDigestClient { commands.digest }

    func run() async throws {
        let report = Report()
        func step(_ name: String, _ body: () async throws -> String) async {
            await report.step(name, body)
        }

        guard try await commands.session.isLoggedIn else { SNCtl.fail("not logged in: run `snctl login <account>` first") }

        var tree: [SNDeviceEntry] = []
        await step("device: space usage") {
            let usage = try await device.spaceUsage()
            return "\(commands.bytes(usage.used)) used"
        }
        await step("device: list / recursively") {
            tree = try await device.list(path: "/", recursive: true)
            return "\(tree.count) entries, \(tree.filter(\.isFolder).count) folders"
        }
        let sample = tree.filter { !$0.isFolder && ($0.size ?? .max) <= 5_000_000 }.min { ($0.size ?? 0) < ($1.size ?? 0) }
        if let sample {
            await step("device: stat by path") {
                guard let found = try await device.entry(atPath: "/" + sample.path) else { throw CheckFailure("not found by its own path") }
                guard found.id == sample.id else { throw CheckFailure("found \(found.id), listed as \(sample.id)") }
                return "/\(found.path)"
            }
            await step("device: download and hash check") {
                let file = try await device.download(sample.id)
                defer { try? FileManager.default.removeItem(at: file) }
                return "\(commands.bytes(sample.size ?? 0)) of /\(sample.path)"
            }
        } else {
            print("SKIP  device: stat and download — no file of 5 MB or less in the account")
        }
        await step("web: user") {
            let user = try await web.user()
            return user.email ?? user.name ?? "id \(user.id.map(String.init) ?? "?")"
        }
        await step("web: list the root (XSRF handshake)") {
            let entries = try await web.list(.root)
            return "\(entries.count) entries: \(entries.prefix(6).map(\.name).joined(separator: ", "))"
        }

        await step("web: folders only, at the top") {
            let folders = try await web.folders()
            return "\(folders.count): \(folders.prefix(8).map(\.name).joined(separator: ", "))"
        }
        await step("web: recycle bin") { "\(try await web.recycleBin().count) entries" }
        if let note = tree.filter({ !$0.isFolder && $0.name.lowercased().hasSuffix(".note") && ($0.size ?? .max) <= 5_000_000 })
            .min(by: { ($0.size ?? 0) < ($1.size ?? 0) }) {
            await step("web: note as PNG pages") {
                let pages = try await web.pngs(ofNote: note.id)
                defer { for page in pages { try? FileManager.default.removeItem(at: page) } }
                return "\(pages.count) pages of /\(note.path)"
            }
        } else {
            print("SKIP  web: note as PNG pages — no note of 5 MB or less in the account")
        }
        await step("socket: the change feed connects") { try await socketCheck() }
        await step("to-do: lists") {
            let lists = try await todo.lists()
            return "\(lists.count): \(lists.prefix(6).map(\.title).joined(separator: ", "))"
        }
        await step("to-do: tasks") {
            let tasks = try await todo.tasks()
            return "\(tasks.count), \(tasks.filter(\.isCompleted).count) completed"
        }
        await step("digest: groups") { "\(try await digest.groups().count)" }
        var withHandwriting: SNDigest?
        await step("digest: digests") {
            let all = try await digest.digests()
            withHandwriting = all.first { $0.handwritingInnerName != nil }
            return "\(all.count)"
        }
        if let withHandwriting {
            await step("digest: a handwritten comment downloads, MD5 checked") {
                guard let file = try await digest.handwriting(of: withHandwriting) else { throw CheckFailure("no file") }
                defer { try? FileManager.default.removeItem(at: file) }
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                return "\(size) bytes of \(withHandwriting.handwritingName ?? "?")"
            }
        }
        await step("digest: fingerprints") { "\(try await digest.fingerprints().count)" }
        await step("digest: tags") { "\(try await digest.tags().count)" }

        if write {
            await writeChecks(report)
            await writeOrganizerChecks(report)
            if digests { await writeDigestChecks(report) }
        } else {
            print("(read-only; `snctl check --write` also uploads, downloads and deletes in a folder of its own)")
        }
        print(report.failures == 0 ? "all passed" : "\(report.failures) failed")
        if report.failures > 0 { exit(2) }
    }

    /// The writing half.
    private func writeChecks(_ report: Report) async {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let folder = "/INBOX/snctl-check-\(stamp)"
        var made: [SNFileID] = []
        let before = report.failures
        func counting(_ name: String, _ body: () async throws -> String) async {
            await report.step(name, body)
        }

        var folderID: SNFileID?
        await counting("device: make \(folder)") {
            let entry = try await device.createFolder(atPath: folder)
            folderID = entry.id
            return "id \(entry.id)"
        }
        for (name, size) in [("small.bin", 1024), ("large.bin", 9 * 1024 * 1024 + 123)] {
            let path = "\(folder)/\(name)"
            let bytes = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
            let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            await counting("device: upload \(name) (\(size > 8 * 1024 * 1024 ? "multipart" : "one PUT"))") {
                let entry = try await device.upload(bytes, toPath: path)
                made.append(entry.id)
                guard entry.contentHash == nil || entry.contentHash == md5 else {
                    throw CheckFailure("the service answered hash \(entry.contentHash ?? "-"), the file's is \(md5)")
                }
                return "id \(entry.id)"
            }
            await counting("device: download \(name) and compare") {
                guard let entry = try await device.entry(atPath: path) else { throw CheckFailure("not found after upload") }
                let file = try await device.download(entry.id)
                defer { try? FileManager.default.removeItem(at: file) }
                guard try Data(contentsOf: file) == bytes else { throw CheckFailure("the bytes came back different") }
                return "\(commands.bytes(Int64(size))) identical"
            }
        }
        if let folderID { await recycleChecks(report, folder: folder, folderID: folderID) }
        for id in made {
            await counting("device: delete file \(id)") {
                try await device.delete(id)
                return ""
            }
        }
        if let folderID {
            await counting("device: delete \(folder)") {
                try await device.delete(folderID)
                return ""
            }
        }

        if report.failures > before { print("(check \(folder) on the account: something there may have been left behind)") }
    }
}

/// The run's tally, one line per step.
final class Report {
    private(set) var failures = 0

    func step(_ name: String, _ body: () async throws -> String) async {
        do {
            let detail = try await body()
            print("PASS  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } catch {
            failures += 1
            print("FAIL  \(name) — \(SNCtl.describe(error))")
        }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
