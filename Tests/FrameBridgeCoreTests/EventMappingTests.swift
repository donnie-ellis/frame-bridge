import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!
private let config = CalendarConfig(people: ["a", "b", "c"], calendars: ["Family": .all, "Mine": .ids(["b", "b"])])

private func date(_ s: String) -> Date { try! Date.ISO8601FormatStyle().parse(s) }

private func values(id: String = "E1", occurrence: String = "2026-10-12T16:00:00Z", start: String, end: String, allDay: Bool = false, loc: String? = nil, notes: String? = nil, calendar: String = "Mine") -> EventValues {
    EventValues(eventIdentifier: id, occurrenceDate: date(occurrence), title: "T", start: date(start), end: date(end), isAllDay: allDay, location: loc, notes: notes, calendarTitle: calendar)
}

@Test func timedEventUsesLocalOffsetAndIdFromOccurrence() throws {
    let e = try #require(EventMapping.map(values(start: "2026-10-12T16:00:00Z", end: "2026-10-12T16:45:00Z"), config: config, timeZone: ny))
    #expect(e.id == "E1:2026-10-12T12:00:00-04:00")
    #expect(e.start == "2026-10-12T12:00:00-04:00")
    #expect(e.end == "2026-10-12T12:45:00-04:00")
    #expect(!e.allDay)
    #expect(e.people == ["b"])
}

@Test func recurringOccurrencesHaveUniqueIds() throws {
    let a = try #require(EventMapping.map(values(occurrence: "2026-10-12T16:00:00Z", start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z"), config: config, timeZone: ny))
    let b = try #require(EventMapping.map(values(occurrence: "2026-10-19T16:00:00Z", start: "2026-10-19T16:00:00Z", end: "2026-10-19T17:00:00Z"), config: config, timeZone: ny))
    #expect(a.id != b.id)
}

@Test func timedEventCrossingMidnightKeepsEnd() throws {
    let e = try #require(EventMapping.map(values(start: "2026-10-13T02:00:00Z", end: "2026-10-13T05:00:00Z"), config: config, timeZone: ny))
    #expect(e.start == "2026-10-12T22:00:00-04:00")
    #expect(e.end == "2026-10-13T01:00:00-04:00")
}

@Test func oneDayAllDayEndsAtNextMidnight() throws {
    let e = try #require(EventMapping.map(values(start: "2026-10-12T04:00:00Z", end: "2026-10-13T03:59:59Z", allDay: true), config: config, timeZone: ny))
    #expect(e.start == "2026-10-12T00:00:00-04:00")
    #expect(e.end == "2026-10-13T00:00:00-04:00")
    #expect(e.allDay)
}

@Test func allDayEndAlreadyAtMidnightIsKept() throws {
    let e = try #require(EventMapping.map(values(start: "2026-10-12T04:00:00Z", end: "2026-10-13T04:00:00Z", allDay: true), config: config, timeZone: ny))
    #expect(e.end == "2026-10-13T00:00:00-04:00")
}

@Test func multiDayAllDayAcrossDSTChange() throws {
    // Oct 31 - Nov 2 local; clocks go back on Nov 1, 2026.
    let e = try #require(EventMapping.map(values(start: "2026-10-31T04:00:00Z", end: "2026-11-03T04:59:59Z", allDay: true), config: config, timeZone: ny))
    #expect(e.start == "2026-10-31T00:00:00-04:00")
    #expect(e.end == "2026-11-03T00:00:00-05:00")
}

@Test func emptyLocationAndNotesAreOmitted() throws {
    let e = try #require(EventMapping.map(values(start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z", loc: "  ", notes: ""), config: config, timeZone: ny))
    #expect(e.loc == nil && e.notes == nil)
    let json = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
    #expect(!json.contains("null") && !json.contains("loc") && !json.contains("notes"))
    let f = try #require(EventMapping.map(values(start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z", loc: " Dental \n", notes: "Bring card."), config: config, timeZone: ny))
    #expect(f.loc == "Dental" && f.notes == "Bring card.")
}

@Test func familyCalendarMapsToEveryPersonAndUnlistedIsDropped() throws {
    let e = try #require(EventMapping.map(values(start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z", calendar: "Family"), config: config, timeZone: ny))
    #expect(e.people == ["a", "b", "c"])
    #expect(EventMapping.map(values(start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z", calendar: "Other"), config: config, timeZone: ny) == nil)
}

@Test func rangeKeepsOverlapsAndSortsByStartEndId() {
    let from = date("2026-10-12T04:00:00Z"), to = date("2026-10-13T04:00:00Z")
    let all = [
        values(id: "ends-at-from", start: "2026-10-11T20:00:00Z", end: "2026-10-12T04:00:00Z"),
        values(id: "starts-at-to", start: "2026-10-13T04:00:00Z", end: "2026-10-13T05:00:00Z"),
        values(id: "zero-at-from", start: "2026-10-12T04:00:00Z", end: "2026-10-12T04:00:00Z"),
        values(id: "b", start: "2026-10-12T10:00:00Z", end: "2026-10-12T11:00:00Z"),
        values(id: "a", start: "2026-10-12T10:00:00Z", end: "2026-10-12T11:00:00Z"),
        values(id: "short", start: "2026-10-12T10:00:00Z", end: "2026-10-12T10:30:00Z"),
        values(id: "spanning", start: "2026-10-11T10:00:00Z", end: "2026-10-14T10:00:00Z"),
    ]
    let ids = EventMapping.eventsInRange(all, config: config, from: from, to: to, timeZone: ny).map { $0.id.split(separator: ":").first.map(String.init)! }
    #expect(ids == ["spanning", "zero-at-from", "short", "a", "b"])
}
