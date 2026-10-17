import Foundation

/// The parts of an EKReminder the chores mapping needs, as plain values.
struct ChoreReminderValues: Sendable, Equatable {
    var id: String
    /// The reminder list's identifier, so a copy and its original can be matched within one list.
    var listId: String
    var title: String
    var notes: String?
    var isCompleted: Bool
    var completionDate: Date?
    var due: DateComponents?
    var isRecurring: Bool
    var recurrence: ChoreRecurrence? = nil
}

/// Reminder values -> wire models. Pure, so the rules are testable without EventKit.
enum ChoreMapping {
    /// A due date without an hour is all-day: local midnight of that day.
    static func due(_ c: DateComponents, calendar: Calendar) -> (date: Date, allDay: Bool)? {
        if c.hour == nil {
            guard let date = calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) else { return nil }
            return (date, true)
        }
        var cal = calendar
        cal.timeZone = c.timeZone ?? calendar.timeZone
        guard let date = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second)) else { return nil }
        return (date, false)
    }

    static func chore(_ r: ChoreReminderValues, who: String, calendar: Calendar = .current) -> Chore {
        let due = r.due.flatMap { due($0, calendar: calendar) }
        let notes = r.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Chore(id: r.id, who: who, title: r.title, done: r.isCompleted,
                     due: due.map { WireDate.string(from: $0.date, timeZone: calendar.timeZone) },
                     allDay: due?.allDay == true ? true : nil,
                     notes: notes?.isEmpty == false ? notes : nil)
    }

    /// Open chores due by the end of today (overdue included) or with no due date, plus chores
    /// completed today. Per person in the order given, then by due, undated last, then title, then id.
    static func list(byPerson people: [(who: String, reminders: [ChoreReminderValues])], now: Date, calendar: Calendar) -> [Chore] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        var chores: [Chore] = []
        for person in people {
            let kept: [(date: Date?, values: ChoreReminderValues)] = person.reminders.compactMap { r in
                let date = r.due.flatMap { due($0, calendar: calendar)?.date }
                if r.isCompleted {
                    guard let done = r.completionDate, done >= today else { return nil }
                } else if let date, date >= tomorrow {
                    return nil
                }
                return (date, r)
            }
            let sorted = kept.sorted { a, b in
                switch (a.date, b.date) {
                case let (x?, y?) where x != y: return x < y
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
                let order = a.values.title.localizedStandardCompare(b.values.title)
                if order != .orderedSame { return order == .orderedAscending }
                return a.values.id < b.values.id
            }
            chores += sorted.map { chore($0.values, who: person.who, calendar: calendar) }
        }
        return chores
    }

    /// Tomorrow's local midnight up to the local midnight after the 6th day after today.
    static func upcomingWindow(now: Date, calendar: Calendar) -> Range<Date> {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        let end = calendar.date(byAdding: .day, value: 7, to: today) ?? start.addingTimeInterval(6 * 86400)
        return start..<end
    }

    /// Every occurrence of the open, dated reminders that falls in the upcoming window, repeating
    /// ones expanded. Sorted by due, then person in the order given, then title, then id. `unexpanded`
    /// lists repeating reminders whose rule couldn't be expanded, with a reason.
    static func upcoming(byPerson people: [(who: String, reminders: [ChoreReminderValues])], now: Date, calendar: Calendar) -> (chores: [UpcomingChore], unexpanded: [(id: String, reason: String)]) {
        let window = upcomingWindow(now: now, calendar: calendar)
        var items: [(date: Date, person: Int, chore: UpcomingChore)] = []
        var unexpanded: [(id: String, reason: String)] = []
        for (index, person) in people.enumerated() {
            for r in person.reminders where !r.isCompleted {
                guard let due = r.due else { continue }
                let result = ChoreRecurrence.occurrences(due: due, rule: r.recurrence, isRecurring: r.isRecurring, window: window, calendar: calendar)
                if let reason = result.unexpanded { unexpanded.append((r.id, reason)) }
                let notes = r.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                for occurrence in result.dates {
                    let day = calendar.dateComponents([.year, .month, .day], from: occurrence.date)
                    let id = r.id + "/" + String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
                    items.append((occurrence.date, index, UpcomingChore(
                        id: id, who: person.who, title: r.title,
                        due: WireDate.string(from: occurrence.date, timeZone: calendar.timeZone),
                        allDay: occurrence.allDay ? true : nil,
                        notes: notes?.isEmpty == false ? notes : nil)))
                }
            }
        }
        items.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            if a.person != b.person { return a.person < b.person }
            let order = a.chore.title.localizedStandardCompare(b.chore.title)
            if order != .orderedSame { return order == .orderedAscending }
            return a.chore.id < b.chore.id
        }
        return (items.map(\.chore), unexpanded)
    }
}
