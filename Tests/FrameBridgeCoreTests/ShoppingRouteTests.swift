import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private struct StubProvider: ShoppingProvider {
    var auth: FeedHealth.Authorization = .fullAccess
    var values: [ReminderValues] = []
    var error: (any Error)?
    func authorization() async -> FeedHealth.Authorization { auth }
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ReminderValues] {
        if let error { throw error }
        return values
    }
    func setCompleted(id: String, listTitle: String, done: Bool) async throws -> (values: ReminderValues, changed: Bool)? {
        if let error { throw error }
        return nil
    }
}

private actor MutableProvider: ShoppingProvider {
    var values: [ReminderValues] = []
    func set(_ v: [ReminderValues]) { values = v }
    func authorization() async -> FeedHealth.Authorization { .fullAccess }
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ReminderValues] { values }
    func setCompleted(id: String, listTitle: String, done: Bool) async throws -> (values: ReminderValues, changed: Bool)? { nil }
}

/// In-memory list that counts saves, like the EventKit one: no save when already matching.
private actor WritableProvider: ShoppingProvider {
    var auth: FeedHealth.Authorization = .fullAccess
    var values: [ReminderValues]
    var error: (any Error)?
    private(set) var saves = 0
    private(set) var lastId: String?
    init(_ values: [ReminderValues], auth: FeedHealth.Authorization = .fullAccess, error: (any Error)? = nil) {
        self.values = values
        self.auth = auth
        self.error = error
    }
    func authorization() async -> FeedHealth.Authorization { auth }
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ReminderValues] { values }
    func setCompleted(id: String, listTitle: String, done: Bool) async throws -> (values: ReminderValues, changed: Bool)? {
        lastId = id
        if let error { throw error }
        guard let i = values.firstIndex(where: { $0.id == id }) else { return nil }
        let changed = values[i].isCompleted != done
        if changed {
            values[i].isCompleted = done
            values[i].completionDate = done ? Date() : nil
            saves += 1
        }
        return (values[i], changed)
    }
}

private let config = ShoppingConfig(list: "Shopping", stores: [Store(id: "grocer", name: "<store>")], defaultStore: "grocer", categories: ["Produce": ["avocados"]])
private func rem(_ id: String, _ title: String) -> ReminderValues { ReminderValues(id: id, title: title, notes: nil, isCompleted: false, completionDate: nil) }

private func feed(_ p: any ShoppingProvider) -> ShoppingFeed {
    ShoppingFeed(config: config, provider: p, logger: Logger(label: "test"))
}

private func get(_ app: some ApplicationProtocol, _ uri: String, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, String(buffer: $0.body)) }
    }
}

private func app(_ p: StubProvider) -> some ApplicationProtocol {
    Application(router: buildRouter(config: TestAuth.config, shopping: feed(p)))
}

@Test func shoppingServesListWithoutNull() async throws {
    let (status, body) = try await get(app(StubProvider(values: [rem("1", "3 avocados"), rem("2", "Soap")])), "/api/shopping")
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let list = try JSONDecoder().decode(ShoppingList.self, from: Data(body.utf8))
    #expect(list.stores == [Store(id: "grocer", name: "<store>")])
    #expect(list.items.map(\.name) == ["avocados", "Soap"])
    #expect(list.items[0].qty == 3 && list.items[0].cat == .produce && list.items[1].cat == .other)
}

@Test func shoppingRequiresToken() async throws {
    let (status, _) = try await get(app(StubProvider()), "/api/shopping", headers: [:])
    #expect(status == .unauthorized)
}

@Test func shoppingIs503WhenSourceIsDown() async throws {
    let cases: [(StubProvider, String)] = [
        (StubProvider(auth: .denied), "reminders access not granted"),
        (StubProvider(auth: .notDetermined), "reminders access not granted"),
        (StubProvider(error: ShoppingSourceError.listNotFound), "list not found"),
        (StubProvider(error: CocoaError(.fileReadUnknown)), "reminders read failed"),
    ]
    for (p, detail) in cases {
        let (status, body) = try await get(app(p), "/api/shopping")
        #expect(status == .serviceUnavailable)
        #expect(body.contains("source_unavailable") && body.contains(detail))
    }
    let none = Application(router: buildRouter(config: TestAuth.config))
    let (status, body) = try await get(none, "/api/shopping")
    #expect(status == .serviceUnavailable && body.contains("not configured"))
}

@Test func healthReportsShoppingState() async throws {
    let ok = app(StubProvider())
    _ = try await get(ok, "/api/shopping")
    let (_, okBody) = try await get(ok, "/healthz")
    let h = try JSONDecoder().decode(Health.self, from: Data(okBody.utf8)).feeds.shopping
    #expect(h.status == .ok && h.authorization == .fullAccess && h.staleAfterSeconds == 300 && h.updatedAt != nil)
    #expect(!okBody.contains("null"))

    let bad = app(StubProvider(error: ShoppingSourceError.listNotFound))
    _ = try await get(bad, "/api/shopping")
    let (_, badBody) = try await get(bad, "/healthz")
    let b = try JSONDecoder().decode(Health.self, from: Data(badBody.utf8)).feeds.shopping
    #expect(b.status == .error && b.detail == "list not found")

    let (_, noneBody) = try await get(Application(router: buildRouter(config: TestAuth.config)), "/healthz")
    let n = try JSONDecoder().decode(Health.self, from: Data(noneBody.utf8)).feeds.shopping
    #expect(n.detail == "not configured" && n.authorization == nil)
}

@Test func rebuildReportsChangesOnly() async throws {
    let p = MutableProvider()
    await p.set([rem("1", "Milk")])
    let f = feed(p)
    #expect(await f.rebuild() == false)
    #expect(await f.rebuild() == false)
    await p.set([rem("1", "Milk"), rem("2", "Eggs")])
    // A GET between rebuilds must not swallow the change.
    _ = try await f.list()
    #expect(await f.rebuild() == true)
    #expect(await f.rebuild() == false)
}

private func patch(_ app: some ApplicationProtocol, _ id: String, _ body: String, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/shopping/\(id)", method: .patch, headers: headers, body: ByteBuffer(string: body)) { ($0.status, String(buffer: $0.body)) }
    }
}

@Test func patchChecksOffAndBackOn() async throws {
    let p = WritableProvider([rem("a", "3 avocados"), rem("b", "Soap")])
    let a = Application(router: buildRouter(config: TestAuth.config, shopping: feed(p)))
    let (status, body) = try await patch(a, "a", #"{"done":true}"#)
    #expect(status == .ok && !body.contains("null"))
    let item = try JSONDecoder().decode(ShoppingItem.self, from: Data(body.utf8))
    #expect(item.done && item.qty == 3 && item.name == "avocados" && item.cat == .produce && item.store == "grocer")
    let (_, listBody) = try await get(a, "/api/shopping")
    let list = try JSONDecoder().decode(ShoppingList.self, from: Data(listBody.utf8))
    #expect(list.items.map(\.id) == ["b", "a"] && list.items[1].done)
    let (undoStatus, undoBody) = try await patch(a, "a", #"{"done":false}"#)
    #expect(undoStatus == .ok && undoBody.contains(#""done":false"#))
    #expect(await p.saves == 2)
}

@Test func patchDecodesPercentEncodedId() async throws {
    let id = "x-apple-reminder://0001"
    let p = WritableProvider([rem(id, "Milk")])
    let a = Application(router: buildRouter(config: TestAuth.config, shopping: feed(p)))
    let (status, _) = try await patch(a, "x-apple-reminder%3A%2F%2F0001", #"{"done":true}"#)
    #expect(status == .ok)
    #expect(await p.lastId == id)
}

@Test func patchUnknownIdIs404() async throws {
    let p = WritableProvider([rem("a", "Milk")])
    let (status, body) = try await patch(Application(router: buildRouter(config: TestAuth.config, shopping: feed(p))), "nope", #"{"done":true}"#)
    #expect(status == .notFound && body.contains("not_found"))
    #expect(await p.saves == 0)
}

@Test func patchIs503WhenSourceIsDown() async throws {
    let cases: [(WritableProvider, String)] = [
        (WritableProvider([rem("a", "Milk")], auth: .denied), "reminders access not granted"),
        (WritableProvider([rem("a", "Milk")], auth: .notDetermined), "reminders access not granted"),
        (WritableProvider([rem("a", "Milk")], auth: .writeOnly), "reminders access not granted"),
        (WritableProvider([rem("a", "Milk")], error: ShoppingSourceError.listNotFound), "list not found"),
        (WritableProvider([rem("a", "Milk")], error: CocoaError(.fileWriteUnknown)), "reminders write failed"),
    ]
    for (p, detail) in cases {
        let (status, body) = try await patch(Application(router: buildRouter(config: TestAuth.config, shopping: feed(p))), "a", #"{"done":true}"#)
        #expect(status == .serviceUnavailable)
        #expect(body.contains("source_unavailable") && body.contains(detail))
        #expect(await p.saves == 0)
    }
    let (status, body) = try await patch(Application(router: buildRouter(config: TestAuth.config)), "a", #"{"done":true}"#)
    #expect(status == .serviceUnavailable && body.contains("not configured"))
}

@Test func patchRequiresTokenAndValidBody() async throws {
    let p = WritableProvider([rem("a", "Milk")])
    let a = Application(router: buildRouter(config: TestAuth.config, shopping: feed(p)))
    let (unauth, _) = try await patch(a, "a", #"{"done":true}"#, headers: [:])
    #expect(unauth == .unauthorized)
    let (bad, body) = try await patch(a, "a", #"{"done":1}"#)
    #expect(bad == .badRequest && body.contains("bad_request"))
    #expect(await p.saves == 0)
}

@Test func patchSendsOneShoppingEventAndNoneForNoOp() async throws {
    let p = WritableProvider([rem("a", "Milk")])
    let f = feed(p)
    _ = await f.rebuild()
    let hub = EventHub()
    let sub = await hub.subscribe()
    let a = Application(router: buildRouter(config: TestAuth.config, shopping: f, events: hub))
    let (status, _) = try await patch(a, "a", #"{"done":true}"#)
    #expect(status == .ok)
    var it = sub.stream.makeAsyncIterator()
    #expect(await it.next()?.contains("shopping") == true)
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
