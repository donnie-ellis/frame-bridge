import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private struct StubProvider: CalendarProvider {
    var auth: FeedHealth.Authorization = .fullAccess
    var values: [EventValues] = []
    var fails = false
    func authorization() async -> FeedHealth.Authorization { auth }
    func events(from: Date, to: Date, calendarTitles: Set<String>) async throws -> [EventValues] {
        if fails { throw CocoaError(.fileReadUnknown) }
        return values
    }
}

private let ny = TimeZone(identifier: "America/New_York")!
private let config = CalendarConfig(people: ["a", "b"], calendars: ["Family": .all])
private func date(_ s: String) -> Date { try! Date.ISO8601FormatStyle().parse(s) }

private func ev(_ id: String, _ start: String, _ end: String, allDay: Bool = false, loc: String? = nil) -> EventValues {
    EventValues(eventIdentifier: id, occurrenceDate: date(start), title: "T", start: date(start), end: date(end), isAllDay: allDay, location: loc, notes: nil, calendarTitle: "Family")
}

private func feed(_ p: StubProvider) -> CalendarFeed {
    CalendarFeed(config: config, provider: p, timeZone: ny, logger: Logger(label: "test"))
}

private let range = "/api/calendar?from=2026-10-12T00:00:00-04:00&to=2026-10-13T00:00:00-04:00"

private func get(_ app: some ApplicationProtocol, _ uri: String, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, String(buffer: $0.body)) }
    }
}

private func app(_ p: StubProvider) -> some ApplicationProtocol {
    Application(router: buildRouter(config: TestAuth.config, calendar: feed(p)))
}

@Test func calendarServesSortedEventsWithoutNull() async throws {
    let p = StubProvider(values: [
        ev("late", "2026-10-12T20:00:00Z", "2026-10-12T21:00:00Z", loc: "Dental"),
        ev("day", "2026-10-12T04:00:00Z", "2026-10-13T03:59:59Z", allDay: true),
    ])
    let (status, body) = try await get(app(p), range)
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let events = try JSONDecoder().decode([Event].self, from: Data(body.utf8))
    #expect(events.map(\.allDay) == [true, false])
    #expect(events[0].end == "2026-10-13T00:00:00-04:00")
    #expect(events[1].loc == "Dental")
    #expect(events[1].people == ["a", "b"])
}

@Test func calendarBadRequests() async throws {
    let a = app(StubProvider())
    for uri in ["/api/calendar", "/api/calendar?from=2026-10-12T00:00:00Z", "/api/calendar?from=x&to=y",
                "/api/calendar?from=2026-10-12T00:00:00Z&to=2026-10-11T00:00:00Z",
                "/api/calendar?from=2026-01-01T00:00:00Z&to=2026-12-01T00:00:00Z"] {
        let (status, body) = try await get(a, uri)
        #expect(status == .badRequest)
        #expect(body.contains("bad_request") && body.contains("detail"))
    }
}

@Test func calendarRequiresToken() async throws {
    let (status, _) = try await get(app(StubProvider()), range, headers: [:])
    #expect(status == .unauthorized)
}

@Test func calendarIs503WithoutAccessOrConfigOrOnFailure() async throws {
    for auth in [FeedHealth.Authorization.denied, .notDetermined, .writeOnly] {
        let (status, body) = try await get(app(StubProvider(auth: auth)), range)
        #expect(status == .serviceUnavailable)
        #expect(body.contains("source_unavailable"))
    }
    let (failed, _) = try await get(app(StubProvider(fails: true)), range)
    #expect(failed == .serviceUnavailable)
    let none = Application(router: buildRouter(config: TestAuth.config))
    let (status, _) = try await get(none, range)
    #expect(status == .serviceUnavailable)
}

@Test func healthReportsCalendarState() async throws {
    let ok = app(StubProvider())
    _ = try await get(ok, range)
    let (_, okBody) = try await get(ok, "/healthz")
    let h = try JSONDecoder().decode(Health.self, from: Data(okBody.utf8)).feeds.calendar
    #expect(h.status == .ok && h.authorization == .fullAccess && h.updatedAt != nil)
    #expect(!okBody.contains("null"))

    let (_, deniedBody) = try await get(app(StubProvider(auth: .denied)), "/healthz")
    let d = try JSONDecoder().decode(Health.self, from: Data(deniedBody.utf8)).feeds.calendar
    #expect(d.status == .error && d.authorization == .denied && d.detail == "calendar access not granted")

    let (_, noneBody) = try await get(Application(router: buildRouter(config: TestAuth.config)), "/healthz")
    let n = try JSONDecoder().decode(Health.self, from: Data(noneBody.utf8)).feeds.calendar
    #expect(n.detail == "not configured" && n.authorization == nil)
}
