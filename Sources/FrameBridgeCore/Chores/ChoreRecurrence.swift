import Foundation

/// An EKRecurrenceRule as plain values, and the expansion of a repeating chore into the days of a window.
struct ChoreRecurrence: Sendable, Equatable {
    enum Frequency: Sendable, Equatable { case daily, weekly, monthly, yearly }
    enum End: Sendable, Equatable { case date(Date), count(Int) }
    struct Weekday: Sendable, Equatable {
        /// 1 (Sunday) to 7.
        var weekday: Int
        var weekNumber: Int
    }

    var frequency: Frequency
    var interval: Int = 1
    var daysOfTheWeek: [Weekday] = []
    /// Negative counts from the month's end.
    var daysOfTheMonth: [Int] = []
    /// 0 means the calendar's first weekday.
    var firstDayOfTheWeek: Int = 0
    var end: End?
    /// Why the rule can't be expanded (a part this code doesn't handle), if it can't.
    var unsupported: String?

    /// Anchors further back than this are not walked day by day.
    private static let maxAnchorAgeYears = 20

    private var unexpandableReason: String? {
        if let unsupported { return unsupported }
        if interval < 1 { return "interval" }
        let fits: Bool
        switch frequency {
        case .daily, .yearly: fits = daysOfTheWeek.isEmpty && daysOfTheMonth.isEmpty
        case .weekly: fits = daysOfTheWeek.allSatisfy { $0.weekNumber == 0 } && daysOfTheMonth.isEmpty
        case .monthly: fits = daysOfTheWeek.isEmpty
        }
        return fits ? nil : "rule parts"
    }

    /// The occurrences of a reminder due at `due` that fall in `window`. `due` is its current
    /// occurrence (all EventKit holds), so expansion walks the local days after it. A rule that
    /// can't be expanded yields the current occurrence only, with the reason.
    static func occurrences(due: DateComponents, rule: ChoreRecurrence?, isRecurring: Bool, window: Range<Date>, calendar: Calendar) -> (dates: [(date: Date, allDay: Bool)], unexpanded: String?) {
        guard let anchor = ChoreMapping.due(due, calendar: calendar) else { return ([], nil) }
        let anchorOnly = window.contains(anchor.date) ? [anchor] : []
        guard let rule else { return (anchorOnly, isRecurring ? "no rule" : nil) }
        if let reason = rule.unexpandableReason { return (anchorOnly, reason) }
        let anchorDay = calendar.startOfDay(for: anchor.date)
        if let oldest = calendar.date(byAdding: .year, value: -maxAnchorAgeYears, to: window.lowerBound), anchorDay < oldest {
            return (anchorOnly, "anchor too old")
        }

        let a = calendar.dateComponents([.year, .month, .day, .weekday], from: anchorDay)
        guard let ay = a.year, let am = a.month, let ad = a.day, let aw = a.weekday else { return (anchorOnly, nil) }
        let firstWeekday = rule.firstDayOfTheWeek == 0 ? calendar.firstWeekday : rule.firstDayOfTheWeek
        let anchorWeekOffset = (aw - firstWeekday + 7) % 7
        let weekdays = rule.daysOfTheWeek.isEmpty ? [aw] : rule.daysOfTheWeek.map(\.weekday)
        let monthDays = rule.daysOfTheMonth.isEmpty ? [ad] : rule.daysOfTheMonth
        let lastEndDay: Date? = if case .date(let d)? = rule.end { calendar.startOfDay(for: d) } else { nil }

        var found = anchorOnly
        var count = 1
        var n = 0
        while true {
            n += 1
            guard let day = calendar.date(byAdding: .day, value: n, to: anchorDay), day < window.upperBound else { break }
            if let lastEndDay, day > lastEndDay { break }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }

            let matches: Bool
            switch rule.frequency {
            case .daily:
                matches = n % rule.interval == 0
            case .weekly:
                let weekday = (aw - 1 + n) % 7 + 1
                matches = ((n + anchorWeekOffset) / 7) % rule.interval == 0 && weekdays.contains(weekday)
            case .monthly:
                let months = (y - ay) * 12 + (m - am)
                let length = calendar.range(of: .day, in: .month, for: day)?.count ?? 31
                matches = months % rule.interval == 0 && monthDays.contains { $0 > 0 ? $0 == d : length + 1 + $0 == d }
            case .yearly:
                matches = (y - ay) % rule.interval == 0 && m == am && d == ad
            }
            guard matches else { continue }
            count += 1
            if case .count(let limit)? = rule.end, count > limit { break }

            var parts = due
            parts.year = y
            parts.month = m
            parts.day = d
            if let occurrence = ChoreMapping.due(parts, calendar: calendar), window.contains(occurrence.date) {
                found.append(occurrence)
            }
        }
        return (found, nil)
    }
}
