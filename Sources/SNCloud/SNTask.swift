// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A to-do list — what the service calls a task group.
///
/// Identifiers here are strings, not snowflakes: the service makes one as the
/// MD5 of the title and the time when the client names none, keeps whatever
/// the client names otherwise, and the default list of every account is `"1"`.
public struct SNTaskList: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let modified: Date?
    public let created: Date?

    public init(id: String, title: String, modified: Date? = nil, created: Date? = nil) {
        self.id = id
        self.title = title
        self.modified = modified
        self.created = created
    }
}

extension SNTaskList: Decodable {
    private enum Keys: String, CodingKey {
        case taskListId, title, lastModified, createTime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .taskListId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        modified = container.time(.lastModified)
        created = container.time(.createTime)
    }
}

/// One task of a to-do list.
///
/// A value to change and hand back: `SNTaskClient.update(_:)` sends **all** of
/// it, because the service overwrites the title, the detail, the status, the
/// importance, the due and completion times, the links and the list on every
/// update — a field left out is a field cleared.
public struct SNTask: Sendable, Equatable, Identifiable {
    /// Empty for a task not yet created; the service names it then.
    public var id: String
    /// The list it is in. `nil` leaves it outside any — the service allows it.
    public var listID: String?
    public var title: String
    public var detail: String?
    /// `status` is `completed`; anything else — `needsAction`, or nothing — is
    /// not. Read from the status only: one client has seen a completion time on
    /// tasks that were not complete.
    public var isCompleted: Bool
    public var due: Date?
    public var completed: Date?
    /// When it was last changed, by whoever changed it. Set by the client on
    /// each create and update, as the service expects.
    public var modified: Date?
    /// An RFC 5545 recurrence rule, as the service's own schema describes it.
    /// `nil` makes a recurring task a plain one on update.
    public var recurrence: String?
    public var isReminderOn: Bool
    /// The service's own word for it; which values it takes is not on record.
    public var importance: String?
    /// What the task points at, as the service stores it: base64 of a JSON
    /// object naming a note — its app, file id, path, page and page id. Kept
    /// opaque, and handed back as it came.
    public var links: String?
    /// Where it sits in the lists the tablet shows. Handed back as it came.
    public var order: SNTaskOrder
    /// The occurrences of a recurring task the tablet has kept apart — one
    /// completed, say, while the rule goes on. Read only: the service's update
    /// does not write them, and its create cannot make one.
    public var occurrences: [SNTaskOccurrence]

    public init(
        id: String = "",
        listID: String? = nil,
        title: String,
        detail: String? = nil,
        isCompleted: Bool = false,
        due: Date? = nil,
        completed: Date? = nil,
        modified: Date? = nil,
        recurrence: String? = nil,
        isReminderOn: Bool = false,
        importance: String? = nil,
        links: String? = nil,
        order: SNTaskOrder = SNTaskOrder(),
        occurrences: [SNTaskOccurrence] = []
    ) {
        self.id = id
        self.listID = listID
        self.title = title
        self.detail = detail
        self.isCompleted = isCompleted
        self.due = due
        self.completed = completed
        self.modified = modified
        self.recurrence = recurrence
        self.isReminderOn = isReminderOn
        self.importance = importance
        self.links = links
        self.order = order
        self.occurrences = occurrences
    }
}

/// The positions a task holds in the tablet's views: in its list, in the
/// planner and in "all", each for the open and the completed tasks, and when
/// each was last moved. Opaque to this package, and kept so that an update does
/// not lose them.
public struct SNTaskOrder: Sendable, Equatable {
    public var sort: Int?
    public var sortCompleted: Int?
    public var plannerSort: Int?
    public var allSort: Int?
    public var allSortCompleted: Int?
    public var sortTime: Int64?
    public var plannerSortTime: Int64?
    public var allSortTime: Int64?

    public init(
        sort: Int? = nil,
        sortCompleted: Int? = nil,
        plannerSort: Int? = nil,
        allSort: Int? = nil,
        allSortCompleted: Int? = nil,
        sortTime: Int64? = nil,
        plannerSortTime: Int64? = nil,
        allSortTime: Int64? = nil
    ) {
        self.sort = sort
        self.sortCompleted = sortCompleted
        self.plannerSort = plannerSort
        self.allSort = allSort
        self.allSortCompleted = allSortCompleted
        self.sortTime = sortTime
        self.plannerSortTime = plannerSortTime
        self.allSortTime = allSortTime
    }
}

/// The task's fields under the service's names. `planerSort` is its spelling.
enum TaskKeys: String, CodingKey {
    case taskId, taskListId, title, detail, status, dueTime, completedTime, lastModified
    case recurrence, isReminderOn, importance, links, isDeleted
    case sort, sortCompleted, planerSort, allSort, allSortCompleted, sortTime, planerSortTime, allSortTime
    case recurrenceId, scheduleRecurTask
}

extension SNTask: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TaskKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        listID = container.text(.taskListId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = container.text(.detail)
        isCompleted = container.text(.status) == SNTask.completedStatus
        due = container.time(.dueTime)
        completed = container.time(.completedTime)
        modified = container.time(.lastModified)
        recurrence = container.text(.recurrence)
        isReminderOn = container.flag(.isReminderOn) ?? false
        importance = container.text(.importance)
        links = container.text(.links)
        order = SNTaskOrder(container)
        let rows = try? container.decodeIfPresent([Marked<SNTaskOccurrence>].self, forKey: .scheduleRecurTask)
        occurrences = (rows ?? []).filter { !$0.deleted }.map(\.value)
    }

    static let completedStatus = "completed"
    static let openStatus = "needsAction"
}

extension SNTaskOrder {
    /// The order fields, from a task's row or an occurrence's.
    init(_ container: KeyedDecodingContainer<TaskKeys>) {
        func position(_ key: TaskKeys) -> Int? { container.integer(key).map(Int.init) }
        self.init(
            sort: position(.sort),
            sortCompleted: position(.sortCompleted),
            plannerSort: position(.planerSort),
            allSort: position(.allSort),
            allSortCompleted: position(.allSortCompleted),
            sortTime: container.integer(.sortTime),
            plannerSortTime: container.integer(.planerSortTime),
            allSortTime: container.integer(.allSortTime)
        )
    }
}

/// One occurrence of a recurring task that has a state of its own: its due
/// time, whether it is done, and where it sits.
public struct SNTaskOccurrence: Sendable, Equatable, Identifiable {
    public let id: String
    /// The recurring task it is an occurrence of.
    public let taskID: String
    public let listID: String?
    public let isCompleted: Bool
    public let due: Date?
    public let completed: Date?
    public let modified: Date?
    public let order: SNTaskOrder

    public init(
        id: String,
        taskID: String,
        listID: String? = nil,
        isCompleted: Bool = false,
        due: Date? = nil,
        completed: Date? = nil,
        modified: Date? = nil,
        order: SNTaskOrder = SNTaskOrder()
    ) {
        self.id = id
        self.taskID = taskID
        self.listID = listID
        self.isCompleted = isCompleted
        self.due = due
        self.completed = completed
        self.modified = modified
        self.order = order
    }
}

extension SNTaskOccurrence: Decodable {
    /// `ScheduleRecurTaskDO`: the occurrence's own `taskId`, and the recurring
    /// task's as `recurrenceId`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TaskKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        taskID = container.text(.recurrenceId) ?? ""
        listID = container.text(.taskListId)
        isCompleted = container.text(.status) == SNTask.completedStatus
        due = container.time(.dueTime)
        completed = container.time(.completedTime)
        modified = container.time(.lastModified)
        order = SNTaskOrder(container)
    }
}

/// A task as the service takes it, whole: every field the update overwrites is
/// sent, and the times go as milliseconds.
struct TaskBody: Encodable {
    let task: SNTask
    let lastModified: Int64

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: TaskKeys.self)
        if !task.id.isEmpty { try container.encode(task.id, forKey: .taskId) }
        try container.encodeIfPresent(task.listID, forKey: .taskListId)
        try container.encode(task.title, forKey: .title)
        try container.encode(task.detail ?? "", forKey: .detail)
        try container.encode(task.isCompleted ? SNTask.completedStatus : SNTask.openStatus, forKey: .status)
        try container.encode(task.due?.milliseconds ?? 0, forKey: .dueTime)
        try container.encodeIfPresent(task.completed?.milliseconds, forKey: .completedTime)
        try container.encode(lastModified, forKey: .lastModified)
        // Sent empty rather than left out: the service keeps the old rule when
        // the field is missing, and there would be no way to drop one.
        try container.encode(task.recurrence ?? "", forKey: .recurrence)
        try container.encode(task.isReminderOn ? "Y" : "N", forKey: .isReminderOn)
        try container.encodeIfPresent(task.importance, forKey: .importance)
        try container.encodeIfPresent(task.links, forKey: .links)
        try container.encodeIfPresent(task.order.sort, forKey: .sort)
        try container.encodeIfPresent(task.order.sortCompleted, forKey: .sortCompleted)
        try container.encodeIfPresent(task.order.plannerSort, forKey: .planerSort)
        try container.encodeIfPresent(task.order.allSort, forKey: .allSort)
        try container.encodeIfPresent(task.order.allSortCompleted, forKey: .allSortCompleted)
        try container.encodeIfPresent(task.order.sortTime, forKey: .sortTime)
        try container.encodeIfPresent(task.order.plannerSortTime, forKey: .planerSortTime)
        try container.encodeIfPresent(task.order.allSortTime, forKey: .allSortTime)
    }
}
