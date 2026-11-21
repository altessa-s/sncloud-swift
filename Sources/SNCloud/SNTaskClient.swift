// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// The protocol client for the to-do API: the lists and the tasks the tablet
/// keeps in its to-do app.
///
/// Schedule requests use the app host, app headers and session token.
///
/// **The service's quirks are its own, and this client keeps to the safe side
/// of them:**
///
/// - **An update overwrites.** The title, the detail, the status, the
///   importance, the due and completion times, the links and the list are
///   written whether the request names them or not. `update(_:)` therefore
///   takes a whole `SNTask` — one read from `tasks()` and changed — and sends
///   all of it.
/// - **Deletes are final.** A task's delete removes the row; a list's removes
///   the list *and every task in it*.
/// - **The listing is whole.** The service also offers a delta since a sync
///   token, and this client does not ask for it: deletions never show in a
///   delta, and before service image 26.10.09 the server's filter for one
///   was unbracketed SQL that did not keep to the account asking — with no
///   way for a client to tell which server it has. A full listing has
///   neither problem.
/// - **Recurring tasks** are read as their rule (`recurrence`); their
///   occurrences, which the official app does not read either, are not.
public actor SNTaskClient {
    let session: SNSession
    let channel: SNChannel
    private let now: @Sendable () -> Date

    /// How many entries one page asks for. The service's own default is 20.
    static let pageSize = 500
    /// A ceiling on pages, against a server whose page token never runs out.
    static let pageLimit = 10_000

    public init(session: SNSession, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.channel = session.channel
        self.now = now
    }

    // MARK: - Lists

    /// Every to-do list of the account, oldest change first.
    public func lists() async throws -> [SNTaskList] {
        try await pages { token, generation in
            let page = try await self.call(
                SNPath.taskLists,
                body: ListPage(maxResults: String(Self.pageSize), pageToken: token),
                changes: false,
                generation: generation,
                as: ListsAnswer.self
            )
            return (page.scheduleTaskGroup ?? [], page.pageToken)
        }
        .uniqued(by: \.value.id)
        .filter { !$0.deleted }
        .map(\.value)
    }

    /// The list with identifier `id`. The service answers an unknown one with
    /// a bare `500` rather than a code, which arrives as `rejected`.
    public func list(_ id: String) async throws -> SNTaskList {
        try await call(
            "\(SNPath.taskList)/\(try Self.component(id))", method: "GET", body: NoBody(), changes: false, as: SNTaskList.self
        )
    }

    /// Make a list, and answer with it as the service named it.
    ///
    /// `id` is the client's to choose; without one the service makes one from
    /// the title and the time. **A taken `id` is not refused**: the service
    /// appends `0` until it is free and answers with that — which is why the
    /// answer is the one to keep.
    @discardableResult
    public func createList(title: String, id: String? = nil) async throws -> SNTaskList {
        let stamp = now()
        let answer = try await call(
            SNPath.taskList,
            body: NewList(taskListId: id, title: title, lastModified: stamp.milliseconds, createTime: stamp.milliseconds),
            changes: true,
            as: ListCreated.self
        )
        guard let made = answer.taskListId, !made.isEmpty else {
            throw SNError.malformedResponse("schedule/group named no list")
        }
        return SNTaskList(id: made, title: title, modified: stamp, created: stamp)
    }

    /// Give a list another title. The service does not check that the list is
    /// there: an unknown `id` is renamed without complaint and without effect.
    public func renameList(_ id: String, to title: String) async throws {
        try await call(
            SNPath.taskList,
            method: "PUT",
            body: RenamedList(taskListId: try Self.component(id), title: title, lastModified: now().milliseconds),
            changes: true
        )
    }

    /// Delete a list **and every task in it**, for good.
    public func deleteList(_ id: String) async throws {
        try await call("\(SNPath.taskList)/\(try Self.component(id))", method: "DELETE", body: NoBody(), changes: true)
        Log.supernote.info("deleted a to-do list with its tasks")
    }

    // MARK: - Tasks

    /// Every task of the account, in every list, oldest change first.
    ///
    /// The service pages by offset over the order of the last change, so a
    /// task changed while the pages are read moves to a later one: it is kept
    /// once, as last seen, but the task that slid into its old place on an
    /// earlier page can be missed. The answer has no total to tell. Pages are
    /// large to make that rare — one page for most accounts.
    public func tasks() async throws -> [SNTask] {
        try await pages { token, generation in
            let page = try await self.call(
                SNPath.tasks,
                body: TaskPage(maxResults: String(Self.pageSize), nextPageTokens: token),
                changes: false,
                generation: generation,
                as: TasksAnswer.self
            )
            return (page.scheduleTask ?? [], page.nextPageToken)
        }
        .uniqued(by: \.value.id)
        .filter { !$0.deleted }
        .map(\.value)
    }

    /// The tasks of the list with identifier `list`.
    public func tasks(in list: String) async throws -> [SNTask] {
        try await tasks().filter { $0.listID == list }
    }

    /// Make a task, and answer with it as the service made it: its identifier
    /// and the time of the change filled in.
    ///
    /// A list that is not there is `notFound`. A task's `id` may be chosen by
    /// the caller; a taken one is not refused but changed, as for a list.
    @discardableResult
    public func create(_ task: SNTask) async throws -> SNTask {
        let stamp = now()
        if !task.id.isEmpty { _ = try Self.component(task.id) }
        let answer = try await call(
            SNPath.task, body: TaskBody(task: task, lastModified: stamp.milliseconds), changes: true, as: TaskCreated.self
        )
        guard let made = answer.taskId, !made.isEmpty else { throw SNError.malformedResponse("schedule/task named no task") }
        var created = task
        created.id = made
        created.modified = stamp
        return created
    }

    /// Write `task` over the one with its identifier — all of it; see the type's
    /// notes — and answer with it as written.
    @discardableResult
    public func update(_ task: SNTask) async throws -> SNTask {
        _ = try Self.component(task.id)
        let stamp = now()
        try await call(SNPath.task, method: "PUT", body: TaskBody(task: task, lastModified: stamp.milliseconds), changes: true)
        var updated = task
        updated.modified = stamp
        return updated
    }

    /// Delete a task for good. The service answers an unknown one with a bare
    /// `500`, which arrives as `rejected`.
    public func delete(_ id: String) async throws {
        try await call("\(SNPath.task)/\(try Self.component(id))", method: "DELETE", body: NoBody(), changes: true)
    }

    // MARK: - Inside

    /// An identifier as the last component of a path: the service's own are
    /// hex digests and `1`, and anything that could step out of the component
    /// is refused before it is sent.
    static func component(_ id: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SNError.malformedResponse("not a to-do identifier: \(id)")
        }
        return id
    }

    /// Every page, from the first to the one that names no next, each asked
    /// for with the token the last one gave.
    private func pages<Item>(
        _ fetch: (_ token: String?, _ generation: Int) async throws -> (items: [Item], next: String?)
    ) async throws -> [Item] {
        let generation = await session.loginGeneration()
        var items: [Item] = []
        var token: String?
        var seen: Set<String> = []
        for _ in 0..<Self.pageLimit {
            let page = try await fetch(token, generation)
            items += page.items
            guard let next = page.next, !next.isEmpty else { return items }
            guard seen.insert(next).inserted else {
                throw SNError.malformedResponse("the to-do listing named page \(next) twice")
            }
            token = next
        }
        throw SNError.malformedResponse("the to-do listing ran past \(Self.pageLimit) pages")
    }

    private func call<Payload: Decodable & Sendable>(
        _ path: String,
        method: String = "POST",
        body: some Encodable & Sendable,
        changes: Bool,
        generation: Int? = nil,
        as payload: Payload.Type
    ) async throws -> Payload {
        // With `channel`, so that the change feed leaves this installation's
        // own changes out of what it announces to it.
        try await channel.call(
            path, on: .app, method: method, body: body, by: session, channel: true, changes: changes,
            generation: generation, as: Payload.self
        )
    }

    private func call(_ path: String, method: String = "POST", body: some Encodable & Sendable, changes: Bool) async throws {
        _ = try await call(path, method: method, body: body, changes: changes, as: SNChannel.Nothing.self)
    }
}

// MARK: - Wire shapes

/// Both page fields are strings to the service — the page size and the page
/// number alike.
private struct ListPage: Encodable {
    let maxResults: String
    let pageToken: String?
}

/// `nextPageTokens`, plural, in the request; `nextPageToken` in the answer.
/// The service's spelling, both.
private struct TaskPage: Encodable {
    let maxResults: String
    let nextPageTokens: String?
}

private struct ListsAnswer: Decodable {
    let pageToken: String?
    let scheduleTaskGroup: [Marked<SNTaskList>]?
}

private struct TasksAnswer: Decodable {
    let nextPageToken: String?
    let scheduleTask: [Marked<SNTask>]?
}

private struct NewList: Encodable {
    let taskListId: String?
    let title: String
    let lastModified: Int64
    let createTime: Int64

    enum CodingKeys: String, CodingKey { case taskListId, title, lastModified, createTime }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(taskListId, forKey: .taskListId)
        try container.encode(title, forKey: .title)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(createTime, forKey: .createTime)
    }
}

private struct RenamedList: Encodable {
    let taskListId: String
    let title: String
    let lastModified: Int64
}

private struct ListCreated: Decodable {
    let taskListId: String?
}

private struct TaskCreated: Decodable {
    let taskId: String?
}
