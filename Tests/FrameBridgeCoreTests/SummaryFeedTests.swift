import Foundation
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
private let people = [Person(id: "maya", name: "Maya", color: "#30a46c")]

private struct StubCalendar: CalendarProvider {
    var fails = false
    func authorization() async -> FeedHealth.Authorization { .fullAccess }
    func events(from: Date, to: Date, calendarTitles: Set<String>) async throws -> [EventValues] {
        if fails { throw CocoaError(.fileReadUnknown) }
        return [EventValues(eventIdentifier: "ev1", occurrenceDate: now, title: "Dentist", start: now, end: now.addingTimeInterval(3600), isAllDay: false, location: "LOC-SENTINEL", notes: nil, calendarTitle: "Family")]
    }
}

private struct StubChores: ChoresProvider {
    func authorization() async -> FeedHealth.Authorization { .fullAccess }
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ChoreReminderValues] {
        [ChoreReminderValues(id: "r1", listId: listTitle, title: "Take out bins", notes: nil, isCompleted: false, completionDate: nil, due: DateComponents(year: 2026, month: 10, day: 12, hour: 18), isRecurring: false)]
    }
    func setDone(id: String, listTitles: [String], done: Bool, now: Date) async throws -> (values: ChoreReminderValues, listTitle: String, changed: Bool)? { nil }
}

/// Replies in order, then keeps failing. Keeps the prompts it was given.
private actor StubGenerator: SummaryGenerating {
    var replies: [Result<String, WorkersAIError>]
    private(set) var prompts: [SummaryPrompt] = []
    init(_ replies: [Result<String, WorkersAIError>]) { self.replies = replies }
    func generate(_ prompt: SummaryPrompt) async throws -> String {
        prompts.append(prompt)
        guard !replies.isEmpty else { throw WorkersAIError.network(-1009) }
        return try replies.removeFirst().get()
    }
}

private func feed(calendarFails: Bool = false, events: EventHub? = nil, logger: Logger = Logger(label: "test")) -> SummaryFeed {
    let calendar = CalendarFeed(config: CalendarConfig(people: ["maya"], calendars: ["Family": .all]), provider: StubCalendar(fails: calendarFails), timeZone: ny, logger: Logger(label: "test"))
    let chores = ChoresFeed(config: ChoresConfig(lists: [ChoreListRef(person: "maya", list: "L1")]), provider: StubChores(), logger: Logger(label: "test"), calendar: cal, now: { now })
    return SummaryFeed(calendar: calendar, chores: chores, people: people, events: events, timeZone: ny, logger: logger)
}

/// The `summary` notices the hub has sent so far.
private func notices(_ hub: EventHub, _ stream: AsyncStream<String>) async -> Int {
    await hub.broadcast("END")
    var count = 0
    for await message in stream {
        if message == "END" { break }
        if message.hasPrefix("event: summary") { count += 1 }
    }
    return count
}

@Test func successServesTodayAndReportsHealthOk() async throws {
    let hub = EventHub(timeZone: ny)
    let (_, stream) = await hub.subscribe()
    let f = feed(events: hub)
    await f.credentialsRead(StubGenerator([.success("Maya has the dentist at noon.")]))
    await f.generate(now: now)
    #expect(try await f.current(now: now) == DaySummary(date: "2026-10-12", text: "Maya has the dentist at noon."))
    let health = await f.health(now: now)
    #expect(health.status == .ok && health.detail == nil)
    #expect(health.updatedAt == "2026-10-12T12:00:00-04:00")
    #expect(health.staleAfterSeconds == 86400)
    #expect(await notices(hub, stream) == 1)
}

@Test func promptHasTheEventsAndChoresAndNothingElse() async throws {
    let generator = StubGenerator([.success("Fine.")])
    let f = feed()
    await f.credentialsRead(generator)
    await f.generate(now: now)
    let prompt = try #require(await generator.prompts.first)
    #expect(prompt.user.contains("\"Dentist\", 12:00 to 13:00, with Maya"))
    #expect(prompt.user.contains("\"Take out bins\", Maya, due 18:00, open"))
    #expect(!(prompt.system + prompt.user).contains("LOC-SENTINEL"))
}

@Test func aFailureAfterASuccessDropsTheSummaryWithOneNotice() async throws {
    let hub = EventHub(timeZone: ny)
    let (_, stream) = await hub.subscribe()
    let f = feed(events: hub)
    await f.credentialsRead(StubGenerator([.success("First."), .failure(.http(500))]))
    await f.generate(now: now)
    await f.generate(now: now.addingTimeInterval(600))
    await f.generate(now: now.addingTimeInterval(1200)) // fails again: nothing left to drop
    await #expect(throws: APIError.self) { _ = try await f.current(now: now) }
    do { _ = try await f.current(now: now) } catch { #expect(error.detail == "Workers AI unreachable" && error.status == .serviceUnavailable) }
    let health = await f.health(now: now)
    #expect(health.status == .error && health.detail == "Workers AI unreachable" && health.updatedAt == "2026-10-12T12:00:00-04:00")
    #expect(await notices(hub, stream) == 2) // the new one, then the drop
}

@Test func aRejectedReplyDropsToo() async throws {
    let f = feed()
    await f.credentialsRead(StubGenerator([.success("First."), .failure(.tooLong)]))
    await f.generate(now: now)
    await f.generate(now: now)
    do { _ = try await f.current(now: now); Issue.record("expected 503") } catch { #expect(error.detail == "reply rejected") }
}

@Test func anUnreadableSourceDropsTheSummary() async throws {
    let f = feed(calendarFails: true)
    await f.credentialsRead(StubGenerator([.success("never used")]))
    await f.generate(now: now)
    do { _ = try await f.current(now: now); Issue.record("expected 503") } catch { #expect(error.detail == "calendar or chores unavailable") }
}

@Test func theSameTextAgainSendsNoSecondNotice() async throws {
    let hub = EventHub(timeZone: ny)
    let (_, stream) = await hub.subscribe()
    let f = feed(events: hub)
    await f.credentialsRead(StubGenerator([.success("Same."), .success("Same.")]))
    await f.generate(now: now)
    await f.generate(now: now)
    #expect(await notices(hub, stream) == 1)
}

@Test func noGeneratorMeansNotConfigured() async {
    let f = feed()
    await f.credentialsRead(nil)
    do { _ = try await f.current(now: now); Issue.record("expected 503") } catch { #expect(error.detail == "not configured") }
    let health = await f.health(now: now)
    #expect(health.status == .error && health.detail == "not configured" && health.updatedAt == nil)
}

@Test func beforeTheFirstRunItIsNotGeneratedYet() async {
    let f = feed()
    await f.credentialsRead(StubGenerator([]))
    do { _ = try await f.current(now: now); Issue.record("expected 503") } catch { #expect(error.detail == "not generated yet") }
    #expect(await SummaryFeed(calendar: nil, chores: nil, people: []).health().detail == "not configured")
}

@Test func yesterdaysSummaryIsNeverServed() async throws {
    let f = feed()
    await f.credentialsRead(StubGenerator([.success("Yesterday.")]))
    await f.generate(now: now)
    let tomorrow = now.addingTimeInterval(86400)
    do { _ = try await f.current(now: tomorrow); Issue.record("expected 503") } catch { #expect(error.detail == "not generated yet") }
    #expect(await f.health(now: tomorrow).status == .error)
}

@Test func dropSendsOneNoticeOnlyWhenThereWasText() async throws {
    let hub = EventHub(timeZone: ny)
    let (_, stream) = await hub.subscribe()
    let f = feed(events: hub)
    await f.credentialsRead(StubGenerator([.success("Text.")]))
    await f.drop(reason: "not generated yet") // nothing to drop
    await f.generate(now: now)
    await f.drop(reason: "daily summary limit reached")
    await f.drop(reason: "daily summary limit reached")
    do { _ = try await f.current(now: now); Issue.record("expected 503") } catch { #expect(error.detail == "daily summary limit reached") }
    #expect(await notices(hub, stream) == 2)
}

@Test func logsNeverCarryTextFromTheDayOrTheModel() async {
    let (logger, box) = CapturingLogHandler.logger()
    let f = feed(logger: logger)
    await f.credentialsRead(StubGenerator([.success("REPLY-SENTINEL"), .failure(.http(503)), .failure(.emptyReply)]))
    await f.generate(now: now)
    await f.generate(now: now)
    await f.generate(now: now)
    let f2 = feed(calendarFails: true, logger: logger)
    await f2.credentialsRead(StubGenerator([]))
    await f2.generate(now: now)
    for entry in box.entries where entry.level >= .info {
        let text = entry.message + " " + entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        for secret in ["Dentist", "Maya", "Take out bins", "REPLY-SENTINEL", "LOC-SENTINEL", "Date:"] { #expect(!text.contains(secret)) }
    }
    #expect(!box.entries.isEmpty)
}
