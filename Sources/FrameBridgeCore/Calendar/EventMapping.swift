import Foundation

/// Plain values from one EventKit occurrence, so the mapping never needs EventKit.
struct EventValues: Sendable, Equatable {
    var eventIdentifier: String
    var occurrenceDate: Date
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var calendarTitle: String
}

enum EventMapping {
    /// Nil when the event's calendar isn't in the config map.
    /// id = eventIdentifier:occurrenceDate. loc/notes = location/notes, trimmed, omitted when empty.
    static func map(_ v: EventValues, config: CalendarConfig, timeZone: TimeZone) -> Event? {
        guard let people = config.people(for: v.calendarTitle) else { return nil }
        let (start, end) = bounds(v, timeZone: timeZone)
        return Event(
            id: v.eventIdentifier + ":" + WireDate.string(from: v.occurrenceDate, timeZone: timeZone),
            title: v.title,
            start: WireDate.string(from: start, timeZone: timeZone),
            end: WireDate.string(from: end, timeZone: timeZone),
            allDay: v.isAllDay,
            people: people,
            loc: nonEmpty(v.location),
            notes: nonEmpty(v.notes)
        )
    }

    /// Start and end as sent: all-day events run from local midnight to the midnight after the last day.
    static func bounds(_ v: EventValues, timeZone: TimeZone) -> (start: Date, end: Date) {
        guard v.isAllDay else { return (v.start, v.end) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: v.start)
        // EventKit ends all-day events at 23:59:59 of the last day; the wire wants the next midnight.
        let lastDay = calendar.startOfDay(for: max(v.start, v.end.addingTimeInterval(-1)))
        return (start, calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86400))
    }

    /// Events overlapping [from, to), sorted by start, then end, then id.
    static func eventsInRange(_ values: [EventValues], config: CalendarConfig, from: Date, to: Date, timeZone: TimeZone) -> [Event] {
        var kept: [(start: Date, end: Date, event: Event)] = []
        for v in values {
            let (start, end) = bounds(v, timeZone: timeZone)
            guard start < to, end > from || start == from else { continue }
            guard let event = map(v, config: config, timeZone: timeZone) else { continue }
            kept.append((start, end, event))
        }
        kept.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.event.id < b.event.id
        }
        return kept.map(\.event)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
