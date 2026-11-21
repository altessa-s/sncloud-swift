// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import SNCloud

/// `snctl watch`: what the change feed announces, printed as it comes.
enum Watch {
    /// Print announcements for `--seconds` (60 unless given), or until the
    /// connection ends.
    static func run(session: SNSession, arguments: [String]) async throws {
        let given = arguments.firstIndex(of: "--seconds").flatMap { index in
            arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
        }
        let seconds = given ?? 60
        let feed = SNChangeFeed(session: session)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await change in feed.changes() {
                    print(describe(change))
                }
                // Ended by the server or the network, not by the timer.
                if !Task.isCancelled { Terminal.note("the connection ended") }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
            }
            try await group.next()
            group.cancelAll()
        }
    }

    static func describe(_ change: SNChange) -> String {
        switch change {
        case .connected:
            return "connected"
        case .files(let files):
            return files.map { file in
                let id = file.id.map(String.init(describing:)) ?? "-"
                return "file   \(file.kind) \(file.isFolder ? "folder " : "")\(id) \(file.newName ?? file.name ?? "") \(file.newPath ?? file.path ?? "")"
            }.joined(separator: "\n")
        case .tasks(let tasks):
            return tasks.map { "to-do  \($0.kind) list \($0.listID ?? "-") task \($0.taskID ?? "-")" }.joined(separator: "\n")
        case .digests(let digests):
            return digests.map { "digest \($0.kind) item \($0.item.rawValue) id \($0.id.map(String.init(describing:)) ?? "-")" }
                .joined(separator: "\n")
        }
    }
}
