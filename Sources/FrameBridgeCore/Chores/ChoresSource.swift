import EventKit
import Foundation

/// Thin EventKit adapter: asks the store, hands plain values to `ChoreMapping`. Read only, except
/// `setDone`: isCompleted on reminders in the configured chore lists, and for the undo of a
/// recurring chore (found by `ChoreUndo.recurringOriginal`) the original's due date and removing
/// the completed copy.
struct EventKitChoresSource: ChoresProvider {
    let store: SharedEventStore

    func authorization() async -> FeedHealth.Authorization {
        SharedEventStore.authorization(for: .reminder)
    }

    func unavailableReason() async -> String? { store.unavailableReason }

    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ChoreReminderValues] {
        let lists = try lists(titled: [listTitle])
        return try await open(in: lists) + completed(in: lists, since: completedSince, until: until)
    }

    func setDone(id: String, listTitles: [String], done: Bool, now: Date) async throws -> (values: ChoreReminderValues, listTitle: String, changed: Bool)? {
        let lists = try lists(titled: listTitles)
        guard let reminder = store.store.calendarItem(withIdentifier: id) as? EKReminder,
              lists.contains(where: { $0.calendarIdentifier == reminder.calendar.calendarIdentifier })
        else { return nil }
        let listTitle = reminder.calendar.title
        guard reminder.isCompleted != done else { return (Self.values(reminder), listTitle, false) }

        if done {
            let savedAt = Date()
            reminder.isCompleted = true
            try store.store.save(reminder, commit: true)
            guard reminder.hasRecurrenceRules else { return (Self.values(reminder), listTitle, true) }
            // EventKit split the reminder: the original moved on, and the completed copy has a new id.
            let original = Self.values(reminder)
            for attempt in 0..<3 {
                if attempt > 0 { try await Task.sleep(for: .milliseconds(300)) }
                let recent = try await completed(in: [reminder.calendar], since: savedAt.addingTimeInterval(-120), until: savedAt.addingTimeInterval(120))
                if let copy = ChoreUndo.completedCopy(of: original, among: recent, savedAt: savedAt) { return (copy, listTitle, true) }
            }
            return (original, listTitle, true)
        }

        let copy = Self.values(reminder)
        if !reminder.hasRecurrenceRules {
            let calendar = Calendar.current
            let since = calendar.startOfDay(for: now)
            let all = try await open(in: [reminder.calendar]) + completed(in: [reminder.calendar], since: since, until: now.addingTimeInterval(120))
            if let original = ChoreUndo.recurringOriginal(for: copy, among: all, now: now, calendar: calendar),
               let originalReminder = store.store.calendarItem(withIdentifier: original.id) as? EKReminder,
               originalReminder.calendar.calendarIdentifier == reminder.calendar.calendarIdentifier {
                // Save the original first: a failure leaves a duplicate, not a lost chore.
                originalReminder.dueDateComponents = reminder.dueDateComponents
                try store.store.save(originalReminder, commit: true)
                try store.store.remove(reminder, commit: true)
                return (Self.values(originalReminder), listTitle, true)
            }
        }
        reminder.isCompleted = false
        try store.store.save(reminder, commit: true)
        return (Self.values(reminder), listTitle, true)
    }

    /// All the lists with these titles. A title with no list throws: an empty calendars list means ALL lists to EventKit.
    private func lists(titled titles: [String]) throws -> [EKCalendar] {
        let all = store.store.calendars(for: .reminder)
        var found: [EKCalendar] = []
        for title in titles {
            let matches = all.filter { $0.title == title }
            guard !matches.isEmpty else { throw ChoresSourceError.listNotFound }
            found += matches
        }
        return found
    }

    private func open(in lists: [EKCalendar]) async throws -> [ChoreReminderValues] {
        try await fetch(store.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
    }

    private func completed(in lists: [EKCalendar], since: Date, until: Date) async throws -> [ChoreReminderValues] {
        try await fetch(store.store.predicateForCompletedReminders(withCompletionDateStarting: since, ending: until, calendars: lists))
    }

    private static func values(_ r: EKReminder) -> ChoreReminderValues {
        ChoreReminderValues(id: r.calendarItemIdentifier, listId: r.calendar.calendarIdentifier, title: r.title ?? "", notes: r.notes,
                            isCompleted: r.isCompleted, completionDate: r.completionDate, due: r.dueDateComponents, isRecurring: r.hasRecurrenceRules,
                            recurrence: recurrence(r.recurrenceRules ?? []))
    }

    private static func recurrence(_ rules: [EKRecurrenceRule]) -> ChoreRecurrence? {
        guard let rule = rules.first else { return nil }
        let frequency: ChoreRecurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return ChoreRecurrence(frequency: .daily, unsupported: "frequency")
        }
        var unsupported: String?
        if rules.count > 1 { unsupported = "multiple rules" }
        else if !(rule.setPositions ?? []).isEmpty { unsupported = "setPositions" }
        else if !(rule.monthsOfTheYear ?? []).isEmpty { unsupported = "monthsOfTheYear" }
        else if !(rule.weeksOfTheYear ?? []).isEmpty { unsupported = "weeksOfTheYear" }
        else if !(rule.daysOfTheYear ?? []).isEmpty { unsupported = "daysOfTheYear" }
        var end: ChoreRecurrence.End?
        if let e = rule.recurrenceEnd {
            if let date = e.endDate { end = .date(date) } else if e.occurrenceCount > 0 { end = .count(e.occurrenceCount) }
        }
        return ChoreRecurrence(frequency: frequency, interval: rule.interval,
                               daysOfTheWeek: (rule.daysOfTheWeek ?? []).map { .init(weekday: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber) },
                               daysOfTheMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
                               firstDayOfTheWeek: rule.firstDayOfTheWeek, end: end, unsupported: unsupported)
    }

    private func fetch(_ predicate: NSPredicate) async throws -> [ChoreReminderValues] {
        try await withCheckedThrowingContinuation { continuation in
            store.store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                continuation.resume(returning: reminders.map(Self.values))
            }
        }
    }
}
