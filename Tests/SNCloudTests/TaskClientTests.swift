// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import SNCloud
import Testing

/// The moment every change in these suites is made at.
private let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

private func taskClient(_ transport: ScriptedTransport) -> SNTaskClient {
    let secrets = InMemorySecrets([.accessToken: liveToken, .account: "a@example.com", .clientID: testClientID])
    let session = SNSession(endpoints: .official, transport: transport, secrets: secrets, sleeper: RecordingSleeper())
    return SNTaskClient(session: session, now: { fixedNow })
}

private let openTask = #"""
{"taskId":"9b2c1f0e5d4a3b2c1d0e9f8a7b6c5d4e","taskListId":"1","title":"Call the bank","detail":"",
 "lastModified":946685000000,"recurrence":"","isReminderOn":"N","status":"needsAction","importance":"",
 "dueTime":0,"completedTime":946684900000,"links":null,"isDeleted":"N","sort":3,"planerSort":1,
 "sortTime":946685000000,"scheduleRecurTask":[]}
"""#

private let doneTask = #"""
{"taskId":"b1","taskListId":"work","title":"Ship it","detail":"before Friday","lastModified":"946685002000",
 "isReminderOn":"Y","status":"completed","dueTime":946686000000,"completedTime":946685002000,
 "links":"eyJhcHBOYW1lIjoibm90ZSJ9","isDeleted":"N"}
"""#

@Test("The tasks are read across pages, with the service's own token names")
func listsTasksAcrossPages() async throws {
    let transport = ScriptedTransport([
        .ok(#""nextPageToken":"2","nextSyncToken":null,"scheduleTask":[\#(openTask)]"#),
        .ok(#""nextPageToken":null,"nextSyncToken":946686000000,"scheduleTask":[\#(doneTask),{"taskId":"gone","title":"x","isDeleted":"Y"}]"#),
    ])
    let tasks = try await taskClient(transport).tasks()

    let first = try #require(transport.calls.first)
    #expect(first.url?.absoluteString == "https://viewer.supernote.com/api/file/schedule/task/all")
    #expect(first.httpMethod == "POST")
    #expect(first.jsonBody["maxResults"] as? String == "500")
    #expect(first.jsonBody["nextPageTokens"] == nil)
    #expect(first.jsonBody["nextSyncToken"] == nil)
    #expect(first.value(forHTTPHeaderField: "x-access-token") == liveToken)
    #expect(first.value(forHTTPHeaderField: "version") == "202407")
    #expect(first.value(forHTTPHeaderField: "X-XSRF-TOKEN") == nil)
    // Plural in the request, singular in the answer: the service's spelling.
    #expect(transport.calls[1].jsonBody["nextPageTokens"] as? String == "2")

    // The row the service marked deleted is not handed on.
    #expect(tasks.map(\.id) == ["9b2c1f0e5d4a3b2c1d0e9f8a7b6c5d4e", "b1"])
    let open = tasks[0]
    #expect(open.listID == "1")
    #expect(!open.isCompleted)
    #expect(open.due == nil)
    #expect(open.detail == nil)
    #expect(open.order.sort == 3)
    #expect(open.order.plannerSort == 1)
    let done = tasks[1]
    #expect(done.isCompleted)
    #expect(done.isReminderOn)
    #expect(done.due == Date(timeIntervalSince1970: 946_686_000))
    #expect(done.modified == Date(timeIntervalSince1970: 946_685_002))
    #expect(done.links == "eyJhcHBOYW1lIjoibm90ZSJ9")
}

@Test("A page token that comes round again stops the listing")
func refusesARepeatedPageToken() async throws {
    let transport = ScriptedTransport([
        .ok(#""nextPageToken":"2","scheduleTask":[]"#),
        .ok(#""nextPageToken":"2","scheduleTask":[]"#),
    ])
    await #expect(throws: SNError.self) { try await taskClient(transport).tasks() }
    #expect(transport.calls.count == 2)
}

@Test("A new task goes out without an identifier and comes back with the service's")
func createsATask() async throws {
    let transport = ScriptedTransport([.ok(#""taskId":"c0ffee""#)])
    let draft = SNTask(listID: "1", title: "Water the plants")

    let made = try await taskClient(transport).create(draft)

    let call = try #require(transport.calls.first)
    #expect(call.url?.path == "/api/file/schedule/task")
    #expect(call.httpMethod == "POST")
    let body = call.jsonBody
    #expect(body["taskId"] == nil)
    #expect(body["taskListId"] as? String == "1")
    #expect(body["title"] as? String == "Water the plants")
    #expect(body["status"] as? String == "needsAction")
    #expect(body["isReminderOn"] as? String == "N")
    // `0` is "no due date": the column may not be null.
    #expect(body["dueTime"] as? Int64 == 0)
    #expect(body["lastModified"] as? Int64 == 1_780_000_000_000)
    #expect(made.id == "c0ffee")
    #expect(made.modified == fixedNow)
}

@Test("An update sends the whole task, since the service overwrites what is left out")
func updatesTheWholeTask() async throws {
    let transport = ScriptedTransport([
        .ok(#""nextPageToken":null,"scheduleTask":[\#(doneTask)]"#),
        .ok(#""taskId":null"#),
    ])
    let client = taskClient(transport)
    var task = try #require(try await client.tasks().first)
    task.isCompleted = false
    task.completed = nil

    try await client.update(task)

    let call = transport.calls[1]
    #expect(call.httpMethod == "PUT")
    #expect(call.url?.path == "/api/file/schedule/task")
    let body = call.jsonBody
    #expect(body["taskId"] as? String == "b1")
    #expect(body["taskListId"] as? String == "work")
    #expect(body["title"] as? String == "Ship it")
    #expect(body["detail"] as? String == "before Friday")
    #expect(body["status"] as? String == "needsAction")
    #expect(body["dueTime"] as? Int64 == 946_686_000_000)
    #expect(body["completedTime"] == nil)
    #expect(body["links"] as? String == "eyJhcHBOYW1lIjoibm90ZSJ9")
    #expect(body["isReminderOn"] as? String == "Y")
    #expect(body["lastModified"] as? Int64 == 1_780_000_000_000)
}

@Test("A delete names the task in its path and carries no body")
func deletesATask() async throws {
    let transport = ScriptedTransport([.ok(), .ok()])
    let client = taskClient(transport)

    try await client.delete("c0ffee")
    try await client.deleteList("work")

    #expect(transport.calls[0].httpMethod == "DELETE")
    #expect(transport.calls[0].url?.path == "/api/file/schedule/task/c0ffee")
    #expect(transport.calls[0].httpBody == nil)
    #expect(transport.calls[1].httpMethod == "DELETE")
    #expect(transport.calls[1].url?.path == "/api/file/schedule/group/work")
}

@Test("An identifier that could step out of its path component is not sent")
func refusesAnIdentifierThatIsAPath() async throws {
    let transport = ScriptedTransport([])
    let client = taskClient(transport)
    await #expect(throws: SNError.self) { try await client.delete("../group/1") }
    await #expect(throws: SNError.self) { try await client.delete("") }
    #expect(transport.calls.isEmpty)
}

@Test("A deleted task is not retried after a server error: it may have gone")
func doesNotRetryADelete() async throws {
    let transport = ScriptedTransport([.init(status: 503)])
    await #expect(throws: SNError.self) { try await taskClient(transport).delete("c0ffee") }
    #expect(transport.calls.count == 1)
}

private let inboxList = #"""
{"taskListId":"1","userId":5,"title":"Inbox","lastModified":0,"isDeleted":"N","createTime":946684800000}
"""#

@Test("Lists are paged by number and made with the service's answer for a name")
func readsAndMakesLists() async throws {
    let transport = ScriptedTransport([
        .ok(#""pageToken":"2","scheduleTaskGroup":[\#(inboxList)]"#),
        .ok(#""pageToken":null,"scheduleTaskGroup":[{"taskListId":"work","title":"Work","lastModified":946685000000,"isDeleted":"N"}]"#),
        .ok(#""taskListId":"work0""#),
        .ok(),
        .ok(#""taskListId":"work0","title":"Office","lastModified":1780000000000,"isDeleted":"N","createTime":1780000000000"#),
    ])
    let client = taskClient(transport)

    let lists = try await client.lists()
    #expect(lists.map(\.title) == ["Inbox", "Work"])
    #expect(lists[0].modified == nil)
    #expect(transport.calls[0].jsonBody["pageToken"] == nil)
    #expect(transport.calls[1].jsonBody["pageToken"] as? String == "2")

    // A taken identifier is not refused: the service appends `0`, and the
    // list it made is the one to keep.
    let made = try await client.createList(title: "Work", id: "work")
    #expect(made.id == "work0")
    #expect(transport.calls[2].jsonBody["taskListId"] as? String == "work")
    #expect(transport.calls[2].jsonBody["createTime"] as? Int64 == 1_780_000_000_000)

    try await client.renameList("work0", to: "Office")
    #expect(transport.calls[3].httpMethod == "PUT")
    #expect(transport.calls[3].url?.path == "/api/file/schedule/group")
    #expect(transport.calls[3].jsonBody["title"] as? String == "Office")

    let read = try await client.list("work0")
    #expect(transport.calls[4].httpMethod == "GET")
    #expect(transport.calls[4].httpBody == nil)
    #expect(transport.calls[4].url?.path == "/api/file/schedule/group/work0")
    #expect(read.title == "Office")
}

@Test("A list that is not there is notFound")
func readsTheToDoErrorCodes() async throws {
    let transport = ScriptedTransport([.refused("E0328", "The task group does not exist")])
    await #expect(throws: SNError.notFound(code: "E0328")) {
        try await taskClient(transport).create(SNTask(listID: "nope", title: "x"))
    }
}

@Test("A task that moved to a later page while the pages were read is kept once, as last seen")
func dropsATaskSeenTwice() async throws {
    let moved = openTask.replacingOccurrences(of: "Call the bank", with: "Call the bank today")
    let transport = ScriptedTransport([
        .ok(#""nextPageToken":"2","scheduleTask":[\#(openTask)]"#),
        .ok(#""nextPageToken":null,"scheduleTask":[\#(doneTask),\#(moved)]"#),
    ])
    let tasks = try await taskClient(transport).tasks()
    #expect(tasks.map(\.id) == ["b1", "9b2c1f0e5d4a3b2c1d0e9f8a7b6c5d4e"])
    #expect(tasks[1].title == "Call the bank today")
}

@Test("A task without a rule is sent with an empty one, so that an update can drop a rule")
func sendsAnEmptyRecurrence() async throws {
    let transport = ScriptedTransport([.ok(#""taskId":null"#)])
    try await taskClient(transport).update(SNTask(id: "b1", listID: "work", title: "Ship it"))
    #expect((transport.calls[0].jsonBody["recurrence"] as? String)?.isEmpty == true)
}

@Test("To-do calls carry `channel`, so the change feed does not announce this installation's own changes back")
func sendsTheChannelHeader() async throws {
    let transport = ScriptedTransport([.ok()])
    try await taskClient(transport).delete("c0ffee")
    let channel = try #require(transport.calls.first?.value(forHTTPHeaderField: "channel"))
    #expect(channel.hasPrefix("\(liveToken)_\(SNDeviceIdentity.currentPlatform)\(testClientID)_"))
}

@Test("A recurring task's kept-apart occurrences are read with it; a deleted one is not")
func readsOccurrences() async throws {
    let recurring = #"""
    {"taskId":"r1","taskListId":"work","title":"Water the plants","recurrence":"RRULE:FREQ=WEEKLY","status":"needsAction",
     "dueTime":946686000000,"isDeleted":"N","scheduleRecurTask":[
      {"taskId":"o1","recurrenceId":"r1","taskListId":"work","userId":7,"lastModified":946685002000,"dueTime":946686000000,
       "completedTime":946685002000,"status":"completed","isDeleted":"N","sort":2},
      {"taskId":"o2","recurrenceId":"r1","userId":7,"status":"needsAction","isDeleted":"Y"}]}
    """#
    let transport = ScriptedTransport([.ok(#""nextPageToken":null,"scheduleTask":[\#(recurring)]"#)])
    let task = try #require(try await taskClient(transport).tasks().first)

    #expect(task.recurrence == "RRULE:FREQ=WEEKLY")
    #expect(task.occurrences == [
        SNTaskOccurrence(
            id: "o1", taskID: "r1", listID: "work", isCompleted: true, due: Date(timeIntervalSince1970: 946_686_000),
            completed: Date(timeIntervalSince1970: 946_685_002), modified: Date(timeIntervalSince1970: 946_685_002),
            order: SNTaskOrder(sort: 2)
        ),
    ])
}
