// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import SNCloud

/// What each command does. One method per command, each a call or a few.
struct Commands {
    let session: SNSession
    let arguments: [String]

    var device: SNDeviceClient { SNDeviceClient(session: session) }
    var web: SNClient { SNClient(session: session) }
    var todo: SNTaskClient { SNTaskClient(session: session) }
    var digest: SNDigestClient { SNDigestClient(session: session) }

    func run(_ command: String) async throws {
        switch command {
        case "login": try await login()
        case "whoami": try await whoami()
        case "logout":
            try await session.logOut()
            print("logged out")
        case "forget":
            try await session.forget()
            print("forgotten here")
        case "ls": try await list()
        case "stat": try await stat()
        case "get": try await get()
        case "put": try await put()
        case "mkdir":
            let folder = try await device.createFolder(atPath: try argument(0, "a path"))
            print(line(folder))
        case "rm": try await remove()
        case "mv": try await move()
        case "space":
            let usage = try await device.spaceUsage()
            print("used \(bytes(usage.used)) of \(usage.allocated.map(bytes) ?? "?")")
        case "web-ls": try await webList()
        case "user":
            let user = try await web.user()
            print("id \(user.id.map(String.init) ?? "?"), name \(user.name ?? "-"), email \(user.email ?? "-")")
        case "bin": try await recycleBin()
        case "restore":
            try await web.restore(try ids())
            print("restored")
        case "purge":
            try await web.deleteForever(try ids())
            print("deleted for good")
        case "empty-bin":
            try await web.emptyRecycleBin()
            print("the recycle bin is empty")
        case "folders":
            let parent = arguments.first.flatMap(Int64.init).map(SNFileID.init(rawValue:)) ?? .root
            for folder in try await web.folders(in: parent) {
                print("\(folder.id.description.padding(toLength: 20, withPad: " ", startingAt: 0)) \(folder.name)\(folder.hasSubfolders ? "/…" : "")")
            }
        case "png": try await png()
        case "watch": try await Watch.run(session: session, arguments: arguments)
        case "todo": try await toDo()
        case "digests": try await digests()
        case "check":
            try await Check(commands: self, write: arguments.contains("--write"), digests: arguments.contains("--digests")).run()
        default:
            SNCtl.fail("unknown command \(command)\n\n\(SNCtl.usage)")
        }
    }

    // MARK: - Account

    private func login() async throws {
        let account = try argument(0, "an account")
        var countryCode: Int?
        if let index = arguments.firstIndex(of: "--country") {
            guard arguments.indices.contains(index + 1), let code = Int(arguments[index + 1]) else {
                SNCtl.fail("--country needs a number, such as 1 or 7")
            }
            countryCode = code
        }
        let password: String
        if let index = arguments.firstIndex(of: "--password-file"), arguments.indices.contains(index + 1) {
            password = try Terminal.password(fromFile: arguments[index + 1])
        } else if let typed = Terminal.password("password for \(account): ") {
            password = typed
        } else {
            SNCtl.fail("no password given (it is read from the terminal, or from --password-file, never from an argument)")
        }
        switch try await session.logIn(account: account, password: password, countryCode: countryCode) {
        case .loggedIn:
            print("logged in as \(account)")
        case .verificationRequired:
            Terminal.note("the service wants this login confirmed: sending a code to \(account)")
            try await session.sendVerificationCode()
            while true {
                guard let code = Terminal.line("code from the email: ") else { SNCtl.fail("no code given") }
                do {
                    try await session.verify(code: code)
                    print("logged in as \(account)")
                    return
                } catch SNError.invalidVerificationCode {
                    Terminal.note("that code was refused; try again (five tries, five minutes)")
                }
            }
        }
    }

    private func whoami() async throws {
        let identity = try await session.identity()
        print("account    \(try await session.account ?? "-")")
        print("logged in  \(try await session.isLoggedIn)")
        if let expiry = try await session.expiry { print("expires    \(expiry.formatted(date: .abbreviated, time: .shortened))") }
        print("device     \(identity.equipmentNo)")
        print("hosts      app \(await session.endpoints.appHost.absoluteString), web \(await session.endpoints.webHost.absoluteString)")
    }

    // MARK: - Device API

    private func list() async throws {
        let path = arguments.first { !$0.hasPrefix("-") } ?? "/"
        let entries = try await device.list(path: path, recursive: arguments.contains("-r"))
        for entry in entries { print(line(entry)) }
        Terminal.note("\(entries.count) entries")
    }

    private func stat() async throws {
        let path = try argument(0, "a path")
        guard let entry = try await device.entry(atPath: path) else { SNCtl.fail("no such entry: \(path)") }
        print(line(entry))
        print("id \(entry.id), path_display \"\(entry.pathDisplay)\", downloadable \(entry.isDownloadable.map(String.init) ?? "?")")
    }

    private func get() async throws {
        let path = try argument(0, "a path")
        guard let entry = try await device.entry(atPath: path) else { SNCtl.fail("no such entry: \(path)") }
        let name = try Self.localName(entry.name)
        var local = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : name)
        // A directory is somewhere to put the file, never something to replace.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
            local = local.appending(path: name)
            if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
                SNCtl.fail("\(local.path) is a directory")
            }
        }
        let file = try await device.download(entry.id, onProgress: progress)
        do {
            // Swapped in one step where something is already there, so a
            // failure leaves the old file as it was rather than gone.
            if FileManager.default.fileExists(atPath: local.path) {
                _ = try FileManager.default.replaceItemAt(local, withItemAt: file)
            } else {
                try FileManager.default.moveItem(at: file, to: local)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        Terminal.note("")
        print("\(local.path) — \(bytes(entry.size ?? 0)), hash checked")
    }

    private func put() async throws {
        let local = URL(fileURLWithPath: try argument(0, "a local file"))
        let path = try argument(1, "a destination path")
        let entry = try await device.upload(contentsOf: local, toPath: path, onProgress: progress)
        Terminal.note("")
        print(line(entry))
    }

    private func remove() async throws {
        let path = try argument(0, "a path")
        guard let entry = try await device.entry(atPath: path) else { SNCtl.fail("no such entry: \(path)") }
        try await device.delete(entry.id)
        print("deleted \(entry.path)")
    }

    private func move() async throws {
        let from = try argument(0, "a source path")
        let to = try argument(1, "a destination path")
        guard let entry = try await device.entry(atPath: from) else { SNCtl.fail("no such entry: \(from)") }
        let moved = try await device.move(entry.id, toPath: to)
        print(moved.map(line) ?? "moved")
    }

    // MARK: - Web API

    private func webList() async throws {
        let folder = arguments.first.flatMap(Int64.init).map(SNFileID.init(rawValue:)) ?? .root
        let entries = try await web.list(folder)
        for entry in entries {
            print("\(entry.isFolder ? "d" : "-") \(entry.id.description.padding(toLength: 20, withPad: " ", startingAt: 0)) "
                + "\(bytes(entry.size ?? 0).padding(toLength: 10, withPad: " ", startingAt: 0)) \(entry.name)")
        }
        Terminal.note("\(entries.count) entries")
    }

    private func recycleBin() async throws {
        let entries = try await web.recycleBin()
        for entry in entries {
            let date = entry.deleted.map { $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)) } ?? ""
            print("\(entry.isFolder ? "d" : "-") \(entry.id.description.padding(toLength: 20, withPad: " ", startingAt: 0)) "
                + "\(bytes(entry.size ?? 0).padding(toLength: 10, withPad: " ", startingAt: 0)) "
                + "\(date.padding(toLength: 20, withPad: " ", startingAt: 0)) \(entry.name)")
        }
        Terminal.note("\(entries.count) entries in the recycle bin")
    }

    private func ids() throws -> [SNFileID] {
        let ids = arguments.compactMap(Int64.init).map(SNFileID.init(rawValue:))
        guard !ids.isEmpty else { SNCtl.fail("this command needs identifiers, as `snctl bin` lists them") }
        return ids
    }

    private func png() async throws {
        let path = try argument(0, "the path of a note")
        guard let entry = try await device.entry(atPath: path) else { SNCtl.fail("no such entry: \(path)") }
        let directory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : ".")
        let pages = try await web.pngs(ofNote: entry.id, onProgress: progress)
        Terminal.note("")
        let stem = (try Self.localName(entry.name) as NSString).deletingPathExtension
        // Each page swapped in one step, as `get` does, and whatever was not
        // placed is removed rather than left in the temporary directory.
        defer { for page in pages { try? FileManager.default.removeItem(at: page) } }
        for (index, page) in pages.enumerated() {
            let target = directory.appending(path: "\(stem)-\(index + 1).png")
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: page)
            } else {
                try FileManager.default.moveItem(at: page, to: target)
            }
            print(target.path)
        }
    }

    // MARK: - To-do and digests

    private func toDo() async throws {
        let lists = try await todo.lists()
        let tasks = try await todo.tasks()
        let titles = Dictionary(lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for task in tasks.sorted(by: { (titles[$0.listID ?? ""] ?? "", $0.title) < (titles[$1.listID ?? ""] ?? "", $1.title) }) {
            let due = task.due.map { " — due \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            print("[\(task.isCompleted ? "x" : " ")] \(titles[task.listID ?? ""] ?? "-"): \(task.title)\(due)")
        }
        Terminal.note("\(lists.count) lists, \(tasks.count) tasks")
    }

    private func digests() async throws {
        let groups = try await digest.groups()
        let names = Dictionary(groups.map { ($0.uniqueIdentifier, $0.name) }, uniquingKeysWith: { first, _ in first })
        let digests = try await digest.digests()
        for item in digests {
            let text = (item.content ?? "").replacingOccurrences(of: "\n", with: " ")
            let tags = item.tags.isEmpty ? "" : " #" + item.tags.joined(separator: " #")
            print("\(names[item.groupIdentifier ?? ""] ?? "-"): \(text.prefix(80))\(tags)")
        }
        Terminal.note("\(groups.count) groups, \(digests.count) digests, \(try await digest.tags().count) tags")
    }

    // MARK: - Shared

    func argument(_ index: Int, _ what: String) throws -> String {
        var plain: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if ["--country", "--password-file"].contains(argument) { skipNext = true; continue }
            if !argument.hasPrefix("-") { plain.append(argument) }
        }
        guard plain.indices.contains(index) else { SNCtl.fail("this command needs \(what)\n\n\(SNCtl.usage)") }
        return plain[index]
    }

    func line(_ entry: SNDeviceEntry) -> String {
        let kind = entry.isFolder ? "d" : "-"
        let size = entry.isFolder ? "" : bytes(entry.size ?? 0)
        let date = entry.modified.map { $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)) } ?? ""
        return "\(kind) \(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(date.padding(toLength: 20, withPad: " ", startingAt: 0)) /\(entry.path)"
    }

    func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    var progress: TransferProgress {
        { done, total in
            guard total > 0 else { return }
            FileHandle.standardError.write(Data("\r\(done * 100 / total)%   ".utf8))
        }
    }
}

extension Commands {
    /// A name the server gave, fit to be a file name here: one component, not
    /// `.` or `..`. A server — a private one especially — is not trusted to
    /// say where on this disk a file goes.
    static func localName(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw SNError.malformedResponse("the server named a file \"\(name)\", which is no file name here")
        }
        return name
    }
}
