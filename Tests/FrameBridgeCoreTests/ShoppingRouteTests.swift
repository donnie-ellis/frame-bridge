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
}

private actor MutableProvider: ShoppingProvider {
    var values: [ReminderValues] = []
    func set(_ v: [ReminderValues]) { values = v }
    func authorization() async -> FeedHealth.Authorization { .fullAccess }
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ReminderValues] { values }
}

private let config = ShoppingConfig(list: "Shopping", stores: [Store(id: "grocer", name: "FreshCo")], defaultStore: "grocer", categories: ["Produce": ["avocados"]])
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
    #expect(list.stores == [Store(id: "grocer", name: "FreshCo")])
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
