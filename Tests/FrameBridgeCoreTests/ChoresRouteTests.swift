import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = ny
    return c
}
private let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
private func due(_ day: Int, _ h: Int = 9) -> DateComponents { DateComponents(year: 2026, month: 10, day: day, hour: h, minute: 0) }

private func rem(_ id: String, _ title: String = "T", list: String = "L1", due d: DateComponents? = nil, recurring: Bool = false) -> ChoreReminderValues {
    ChoreReminderValues(id: id, listId: list, title: title, notes: nil, isCompleted: false, completionDate: nil, due: d, isRecurring: recurring)
}

/// In-memory lists. Completing a recurring reminder splits it like EventKit; undoing the copy goes through ChoreUndo.
private actor StubProvider: ChoresProvider {
    var auth: FeedHealth.Authorization = .fullAccess
    var values: [ChoreReminderValues]
    var error: (any Error)?
    private(set) var saves = 0
    private(set) var removed: [String] = []
    private(set) var lastId: String?
    init(_ values: [ChoreReminderValues], auth: FeedHealth.Authorization = .fullAccess, error: (any Error)? = nil) {
        self.values = values
        self.auth = auth
        self.error = error
    }
    func authorization() async -> FeedHealth.Authorization { auth }
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ChoreReminderValues] {
        if let error { throw error }
        return values.filter { $0.listId == listTitle }
    }
    func setDone(id: String, listTitles: [String], done: Bool, now: Date) async throws -> (values: ChoreReminderValues, listTitle: String, changed: Bool)? {
        lastId = id
        if let error { throw error }
        guard let i = values.firstIndex(where: { $0.id == id }), listTitles.contains(values[i].listId) else { return nil }
        let r = values[i]
        guard r.isCompleted != done else { return (r, r.listId, false) }
        if done {
            saves += 1
            if r.isRecurring {
                var c = r
                c.id = r.id + "-copy"
                c.isCompleted = true
                c.completionDate = now
                c.isRecurring = false
                values[i].due = due(13)
                values.append(c)
                return (c, r.listId, true)
            }
            values[i].isCompleted = true
            values[i].completionDate = now
            return (values[i], r.listId, true)
        }
        if let original = ChoreUndo.recurringOriginal(for: r, among: values, now: now, calendar: cal), let o = values.firstIndex(where: { $0.id == original.id }) {
            values[o].due = r.due
            values.remove(at: i)
            removed.append(r.id)
            saves += 2
            return (values[o], r.listId, true)
        }
        values[i].isCompleted = false
        values[i].completionDate = nil
        saves += 1
        return (values[i], r.listId, true)
    }
}

private let config = ChoresConfig(lists: [ChoreListRef(person: "alex", list: "L1"), ChoreListRef(person: "maya", list: "L2")])

private func feed(_ p: any ChoresProvider) -> ChoresFeed {
    ChoresFeed(config: config, provider: p, logger: Logger(label: "test"), calendar: cal, now: { now })
}

private func app(_ f: ChoresFeed?, events: EventHub = EventHub()) -> some ApplicationProtocol {
    Application(router: buildRouter(config: TestAuth.config, chores: f, events: events))
}

private func get(_ app: some ApplicationProtocol, _ uri: String = "/api/chores", headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, String(buffer: $0.body)) }
    }
}

private func patch(_ app: some ApplicationProtocol, _ id: String, _ body: String, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/chores/\(id)", method: .patch, headers: headers, body: ByteBuffer(string: body)) { ($0.status, String(buffer: $0.body)) }
    }
}

@Test func choresRequireToken() async throws {
    let (status, _) = try await get(app(feed(StubProvider([]))), headers: [:])
    #expect(status == .unauthorized)
    let (p, _) = try await patch(app(feed(StubProvider([]))), "a", #"{"done":true}"#, headers: [:])
    #expect(p == .unauthorized)
}

@Test func choresServeListWithoutNull() async throws {
    let p = StubProvider([rem("a", "Bins", list: "L1", due: due(12, 18)), rem("m", "Fish", list: "L2"), rem("later", list: "L1", due: due(20))])
    let (status, body) = try await get(app(feed(p)))
    #expect(status == .ok && !body.contains("null"))
    let list = try JSONDecoder().decode(ChoreList.self, from: Data(body.utf8))
    #expect(list.chores.map(\.id) == ["a", "m"])
    #expect(list.chores.map(\.who) == ["alex", "maya"])
    #expect(list.chores[0].due == "2026-10-12T18:00:00-04:00")
}

@Test func choresAre503WhenSourceIsDown() async throws {
    let cases: [(StubProvider, String)] = [
        (StubProvider([], auth: .denied), "reminders access not granted"),
        (StubProvider([], error: ChoresSourceError.listNotFound), "list not found"),
        (StubProvider([], error: CocoaError(.fileReadUnknown)), "reminders read failed"),
    ]
    for (p, detail) in cases {
        let (status, body) = try await get(app(feed(p)))
        #expect(status == .serviceUnavailable && body.contains("source_unavailable") && body.contains(detail))
    }
    let (status, body) = try await get(app(nil))
    #expect(status == .serviceUnavailable && body.contains("not configured"))
    let (pStatus, _) = try await patch(app(nil), "a", #"{"done":true}"#)
    #expect(pStatus == .serviceUnavailable)
}

@Test func chores_healthReportsChoresState() async throws {
    let ok = app(feed(StubProvider([])))
    _ = try await get(ok)
    let (_, okBody) = try await get(ok, "/healthz")
    let h = try JSONDecoder().decode(Health.self, from: Data(okBody.utf8)).feeds.chores
    #expect(h.status == .ok && h.authorization == .fullAccess && h.staleAfterSeconds == 300 && h.updatedAt != nil)

    let bad = app(feed(StubProvider([], error: ChoresSourceError.listNotFound)))
    _ = try await get(bad)
    let b = try JSONDecoder().decode(Health.self, from: Data(try await get(bad, "/healthz").1.utf8)).feeds.chores
    #expect(b.status == .error && b.detail == "list not found")

    let n = try JSONDecoder().decode(Health.self, from: Data(try await get(app(nil), "/healthz").1.utf8)).feeds.chores
    #expect(n.status == .error && n.detail == "not configured" && n.authorization == nil)
}

@Test func chores_patchChecksOffAndBackOn() async throws {
    let p = StubProvider([rem("a", "Bins", due: due(12, 18))])
    let a = app(feed(p))
    let (status, body) = try await patch(a, "a", #"{"done":true}"#)
    #expect(status == .ok && !body.contains("null"))
    let chore = try JSONDecoder().decode(Chore.self, from: Data(body.utf8))
    #expect(chore.done && chore.id == "a" && chore.who == "alex")
    let (undo, undoBody) = try await patch(a, "a", #"{"done":false}"#)
    #expect(undo == .ok && undoBody.contains(#""done":false"#))
    #expect(await p.removed.isEmpty)
}

@Test func chores_recurringCheckOffReturnsCopyAndUndoRestoresOriginal() async throws {
    let p = StubProvider([rem("orig", "Bins", due: due(12), recurring: true)])
    let a = app(feed(p))
    let (_, body) = try await patch(a, "orig", #"{"done":true}"#)
    let copy = try JSONDecoder().decode(Chore.self, from: Data(body.utf8))
    #expect(copy.id == "orig-copy" && copy.done && copy.due == "2026-10-12T09:00:00-04:00")
    let (_, listBody) = try await get(a)
    let listed = try JSONDecoder().decode(ChoreList.self, from: Data(listBody.utf8))
    #expect(listed.chores.map(\.id) == ["orig-copy"])

    let (status, undoBody) = try await patch(a, "orig-copy", #"{"done":false}"#)
    let restored = try JSONDecoder().decode(Chore.self, from: Data(undoBody.utf8))
    #expect(status == .ok && restored.id == "orig" && !restored.done && restored.due == "2026-10-12T09:00:00-04:00")
    #expect(await p.removed == ["orig-copy"])
}

@Test func chores_patchDecodesPercentEncodedId() async throws {
    let id = "x-apple-reminder://0001"
    let p = StubProvider([rem(id)])
    let (status, _) = try await patch(app(feed(p)), "x-apple-reminder%3A%2F%2F0001", #"{"done":true}"#)
    #expect(status == .ok)
    #expect(await p.lastId == id)
}

@Test func chores_patchUnknownOrOtherListIs404() async throws {
    let p = StubProvider([rem("a"), rem("other", list: "Elsewhere")])
    let a = app(feed(p))
    for id in ["nope", "other"] {
        let (status, body) = try await patch(a, id, #"{"done":true}"#)
        #expect(status == .notFound && body.contains("not_found"))
    }
    #expect(await p.saves == 0)
}

@Test func chores_patchIs503WhenSourceIsDownAnd400ForBadBody() async throws {
    let cases: [(StubProvider, String)] = [
        (StubProvider([rem("a")], auth: .denied), "reminders access not granted"),
        (StubProvider([rem("a")], error: ChoresSourceError.listNotFound), "list not found"),
        (StubProvider([rem("a")], error: CocoaError(.fileWriteUnknown)), "reminders write failed"),
    ]
    for (p, detail) in cases {
        let (status, body) = try await patch(app(feed(p)), "a", #"{"done":true}"#)
        #expect(status == .serviceUnavailable && body.contains(detail))
    }
    let p = StubProvider([rem("a")])
    for bad in [#"{"done":1}"#, #"{}"#, #"{"done":true,"x":1}"#, "nope"] {
        let (status, body) = try await patch(app(feed(p)), "a", bad)
        #expect(status == .badRequest && body.contains("bad_request"))
    }
    #expect(await p.saves == 0)
}

@Test func chores_patchSendsOneChoresEventAndNoneForNoOp() async throws {
    let p = StubProvider([rem("a")])
    let f = feed(p)
    _ = await f.rebuild()
    let hub = EventHub()
    let sub = await hub.subscribe()
    let a = app(f, events: hub)
    let (status, _) = try await patch(a, "a", #"{"done":true}"#)
    #expect(status == .ok)
    var it = sub.stream.makeAsyncIterator()
    #expect(await it.next()?.contains("event: chores") == true)
    // The EKEventStoreChanged rebuild after our own write must not notify again.
    #expect(await f.rebuild() == false)
    let (again, _) = try await patch(a, "a", #"{"done":true}"#)
    #expect(again == .ok)
    #expect(await p.saves == 1)
    await hub.remove(sub.id)
    var rest: [String] = []
    while let m = await it.next() { rest.append(m) }
    #expect(rest.isEmpty)
}
