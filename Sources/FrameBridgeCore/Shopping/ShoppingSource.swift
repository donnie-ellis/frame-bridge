import EventKit
import Foundation

/// Thin EventKit adapter: asks the store, hands plain values to `ItemMapping`. Read only, except reminder check-off (setCompleted).
struct EventKitShoppingSource: ShoppingProvider {
    let store: SharedEventStore

    func authorization() async -> FeedHealth.Authorization {
        SharedEventStore.authorization(for: .reminder)
    }

    func unavailableReason() async -> String? { store.unavailableReason }

    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ReminderValues] {
        let lists = store.store.calendars(for: .reminder).filter { $0.title == listTitle }
        // An empty calendars list means ALL lists to EventKit.
        guard !lists.isEmpty else { throw ShoppingSourceError.listNotFound }
        let open = store.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let done = store.store.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: until, calendars: lists)
        return try await fetch(open) + fetch(done)
    }

    func setCompleted(id: String, listTitle: String, done: Bool) async throws -> (values: ReminderValues, changed: Bool)? {
        let lists = store.store.calendars(for: .reminder).filter { $0.title == listTitle }
        guard !lists.isEmpty else { throw ShoppingSourceError.listNotFound }
        guard let reminder = store.store.calendarItem(withIdentifier: id) as? EKReminder,
              lists.contains(where: { $0.calendarIdentifier == reminder.calendar.calendarIdentifier })
        else { return nil }
        let changed = reminder.isCompleted != done
        if changed {
            reminder.isCompleted = done
            try store.store.save(reminder, commit: true)
        }
        let values = ReminderValues(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes, isCompleted: reminder.isCompleted, completionDate: reminder.completionDate)
        return (values, changed)
    }

    private func fetch(_ predicate: NSPredicate) async throws -> [ReminderValues] {
        try await withCheckedThrowingContinuation { continuation in
            store.store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                continuation.resume(returning: reminders.map {
                    ReminderValues(id: $0.calendarItemIdentifier, title: $0.title ?? "", notes: $0.notes, isCompleted: $0.isCompleted, completionDate: $0.completionDate)
                })
            }
        }
    }
}
