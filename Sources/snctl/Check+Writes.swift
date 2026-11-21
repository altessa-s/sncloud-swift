// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import SNCloud

/// The writing steps beyond the file tree: the recycle bin, the to-do list and
/// the digests.
extension Check {
    /// The recycle bin, with a file of its own: deleted through the web API —
    /// the device API's delete removes for good and skips the bin — found
    /// there, restored, deleted again, and deleted for good, which leaves the
    /// bin as it was found.
    func recycleChecks(_ report: Report, folder: String, folderID: SNFileID) async {
        var file: SNFileID?
        await report.step("web: delete a file into the recycle bin") {
            let entry = try await device.upload(Data("snctl recycle check".utf8), toPath: "\(folder)/recycled.txt")
            file = entry.id
            try await web.delete([entry.id], from: folderID)
            guard try await web.recycleBin().contains(where: { $0.id == entry.id && $0.name == "recycled.txt" }) else {
                throw CheckFailure("not in the bin")
            }
            return "id \(entry.id)"
        }
        guard let file else { return }
        await report.step("web: restore it, delete it again, delete it for good") {
            try await web.restore([file])
            guard let back = try await device.entry(file) else { throw CheckFailure("not in the tree after the restore") }
            try await web.delete([file], from: folderID)
            try await web.deleteForever([file])
            guard try await !web.recycleBin().contains(where: { $0.id == file }) else { throw CheckFailure("still in the bin") }
            return "/\(back.path) came back, then went for good"
        }
    }

    /// A digest group and a digest in it, made, read back, changed and deleted.
    /// Asked for apart (`--digests`): the service only marks these deleted, so
    /// each run leaves two such rows on the account.
    func writeDigestChecks(_ report: Report) async {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let name = "snctl-check-\(stamp)"
        let unique = UUID().uuidString.lowercased()
        let text = "snctl check passage \(stamp)"
        var group: SNDigestID?
        await report.step("digest: make group \(name)") {
            group = try await digest.createGroup(named: name, uniqueIdentifier: unique)
            guard try await digest.groups().contains(where: { $0.id == group && $0.name == name }) else {
                throw CheckFailure("not listed after it was made")
            }
            return "id \(group.map(String.init(describing:)) ?? "-")"
        }
        guard let group else { return }
        var made: SNDigestID?
        await report.step("digest: make a digest in it and read it back") {
            let id = try await digest.create(SNDigestDraft(content: text, groupIdentifier: unique, tags: ["snctl", "check"], author: "snctl"))
            made = id
            guard let read = try await digest.digests(in: unique).first(where: { $0.id == id }) else {
                throw CheckFailure("not listed in its group")
            }
            guard read.content == text, read.tags == ["snctl", "check"], read.md5Hash != nil else {
                throw CheckFailure("read back as \(String(describing: read.content)), tags \(read.tags)")
            }
            guard try await digest.fingerprints(in: unique).contains(where: { $0.id == id && $0.md5Hash == read.md5Hash }) else {
                throw CheckFailure("no fingerprint with its hash")
            }
            return "id \(id), content, tags and fingerprint kept"
        }
        if let made {
            await report.step("digest: a handwritten comment up, onto it, and back") {
                let strokes = Data("snctl handwriting \(stamp)".utf8)
                let file = try FileManager.default.temporaryDirectory.appending(path: "snctl-\(UUID().uuidString).mark")
                try strokes.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let handwriting = try await digest.uploadHandwriting(contentsOf: file)
                try await digest.update(made, with: SNDigestDraft(handwriting: handwriting))
                guard let read = try await digest.digests([made]).first, read.handwritingInnerName == handwriting.innerName else {
                    throw CheckFailure("the digest does not name it")
                }
                guard let back = try await digest.handwriting(of: read) else { throw CheckFailure("no file") }
                defer { try? FileManager.default.removeItem(at: back) }
                guard try Data(contentsOf: back) == strokes else { throw CheckFailure("the bytes came back different") }
                return "\(handwriting.innerName), identical"
            }
            await report.step("digest: change its comment, read it by id") {
                try await digest.update(made, with: SNDigestDraft(comment: "changed"))
                guard let read = try await digest.digests([made]).first else { throw CheckFailure("not found by id") }
                guard read.comment == "changed", read.content == text else {
                    throw CheckFailure("comment \(String(describing: read.comment)), content \(String(describing: read.content))")
                }
                return "comment changed, content kept"
            }
            await report.step("digest: delete the digest") {
                try await digest.delete(made)
                guard try await digest.digests([made]).isEmpty else { throw CheckFailure("still found by id") }
                return "marked deleted, no longer listed"
            }
        }
        await report.step("digest: rename and delete the group") {
            try await digest.updateGroup(group, name: name + "-renamed", description: "snctl")
            guard try await digest.groups().contains(where: { $0.id == group && $0.name == name + "-renamed" }) else {
                throw CheckFailure("the name did not change")
            }
            try await digest.deleteGroup(group)
            guard try await !digest.groups().contains(where: { $0.id == group }) else { throw CheckFailure("still listed") }
            return "marked deleted, no longer listed"
        }
    }

    /// The to-do list and the tag it makes, changes and deletes — both deleted
    /// for good, unlike a digest or a digest group, which the service only
    /// marks, and which this check therefore does not make.
    func writeOrganizerChecks(_ report: Report) async {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let title = "snctl-check-\(stamp)"
        let before = report.failures
        var list: SNTaskList?
        await report.step("to-do: make list \(title)") {
            list = try await todo.createList(title: title)
            return "id \(list?.id ?? "-")"
        }
        if let list {
            var task: SNTask?
            await report.step("to-do: make a task") {
                task = try await todo.create(SNTask(listID: list.id, title: "check", due: Date().addingTimeInterval(86_400)))
                return "id \(task?.id ?? "-")"
            }
            if var task {
                await report.step("to-do: complete it and read it back") {
                    task.isCompleted = true
                    task.completed = Date()
                    try await todo.update(task)
                    guard let read = try await todo.tasks(in: list.id).first(where: { $0.id == task.id }) else {
                        throw CheckFailure("not listed after the update")
                    }
                    guard read.isCompleted, read.title == "check", read.due != nil else {
                        throw CheckFailure("read back as completed \(read.isCompleted), title \(read.title), due \(String(describing: read.due))")
                    }
                    return "completed, title and due date kept"
                }
                await report.step("to-do: delete the task") {
                    try await todo.delete(task.id)
                    return ""
                }
            }
            await report.step("to-do: rename and delete the list") {
                try await todo.renameList(list.id, to: title + "-renamed")
                guard try await todo.list(list.id).title == title + "-renamed" else { throw CheckFailure("the title did not change") }
                try await todo.deleteList(list.id)
                return ""
            }
        }
        var tag: SNDigestID?
        await report.step("digest: make tag \(title)") {
            tag = try await digest.createTag(named: title)
            return "id \(tag.map(String.init(describing:)) ?? "-")"
        }
        if let tag {
            await report.step("digest: rename and delete the tag") {
                try await digest.renameTag(tag, to: title + "-renamed")
                guard try await digest.tags().contains(where: { $0.id == tag && $0.name == title + "-renamed" }) else {
                    throw CheckFailure("the name did not change")
                }
                try await digest.deleteTag(tag)
                return ""
            }
        }
        if report.failures > before { print("(look for \(title) among the to-do lists and digest tags: it may have been left behind)") }
    }

    /// The change feed opened, and closed again once it says it is connected.
    func socketCheck() async throws -> String {
        let feed = SNChangeFeed(session: commands.session)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await change in feed.changes() where change == .connected {
                    return "connected to \(await commands.session.endpoints.socketHost.host() ?? "?")"
                }
                throw CheckFailure("closed before it connected")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw CheckFailure("not connected in 20 seconds")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}
