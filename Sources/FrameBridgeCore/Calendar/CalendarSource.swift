import EventKit
import Foundation
import Logging

/// Thin EventKit adapter: asks the store, hands plain values to `EventMapping`. Read only.
struct EventKitCalendarSource: CalendarProvider {
    let store: SharedEventStore
    var logger = Logger(label: "frame-bridge.calendar")

    func authorization() async -> FeedHealth.Authorization {
        SharedEventStore.authorization(for: .event)
    }

    func unavailableReason() async -> String? { store.unavailableReason }

    func events(from: Date, to: Date, calendarTitles: Set<String>) async throws -> [EventValues] {
        let matching = store.store.calendars(for: .event).filter { calendarTitles.contains($0.title) }
        let duplicates = matching.count - Set(matching.map(\.title)).count
        if duplicates > 0 {
            logger.warning("calendars share a title, reading all of them", metadata: ["count": .stringConvertible(duplicates)])
            logger.debug("duplicate calendar titles", metadata: ["titles": .string(Dictionary(grouping: matching, by: \.title).filter { $1.count > 1 }.keys.sorted().joined(separator: ", "))])
        }
        // An empty calendars list means ALL calendars to EventKit.
        guard !matching.isEmpty else { return [] }
        let predicate = store.store.predicateForEvents(withStart: from, end: to, calendars: matching)
        return store.store.events(matching: predicate).map { e in
            EventValues(
                eventIdentifier: e.eventIdentifier ?? e.calendarItemIdentifier,
                occurrenceDate: e.occurrenceDate ?? e.startDate,
                title: e.title ?? "",
                start: e.startDate,
                end: e.endDate,
                isAllDay: e.isAllDay,
                location: e.location,
                notes: e.notes,
                calendarTitle: e.calendar.title,
                isOrganizerCopy: e.organizer?.isCurrentUser == true
            )
        }
    }
}
