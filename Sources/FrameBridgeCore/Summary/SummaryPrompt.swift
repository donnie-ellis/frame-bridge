import Foundation

/// What goes to the model. The system text is fixed. The user text is built from the date, today's
/// events and chores, and people's names: nothing else. Titles and names are private.
struct SummaryPrompt: Equatable, Sendable {
    let system: String
    let user: String

    static let systemText = "You write the summary of a family's day for a wall display. Use only the data you are given. Write one to three plain sentences: no markdown, no lists, no headings, no emoji. Do not invent anything."

    /// Reads only `title`, `start`, `end`, `allDay` and `people` of an event, and `title`, `who`,
    /// `due`, `allDay` and `done` of a chore. A person id that isn't in `people` is left out.
    static func build(date: Date, events: [Event], chores: [Chore], people: [Person], timeZone: TimeZone) -> SummaryPrompt {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = SummaryDay.string(for: date, timeZone: timeZone)
        let names = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let parser = ISO8601DateFormatter()

        func clock(_ text: String) -> String? {
            guard let d = parser.date(from: text) else { return nil }
            let time = hhmm(d, calendar)
            let day = SummaryDay.string(for: d, timeZone: timeZone)
            return day == today ? time : "\(day) \(time)"
        }

        var lines = ["Date: \(weekday(date, timeZone)) \(today)", "Events:"]
        if events.isEmpty { lines.append("- none") }
        for e in events {
            var parts = [quoted(e.title)]
            if e.allDay {
                parts.append("all day")
            } else if let start = clock(e.start), let end = clock(e.end) {
                parts.append("\(start) to \(end)")
            }
            let who = e.people.compactMap { names[$0] }.map(flat)
            if !who.isEmpty { parts.append("with " + who.joined(separator: ", ")) }
            lines.append("- " + parts.joined(separator: ", "))
        }
        lines.append("Chores:")
        if chores.isEmpty { lines.append("- none") }
        for c in chores {
            var parts = [quoted(c.title)]
            if let name = names[c.who] { parts.append(flat(name)) }
            if let due = c.due, let dueDate = parser.date(from: due) {
                let dueDay = SummaryDay.string(for: dueDate, timeZone: timeZone)
                if dueDay < today {
                    parts.append("overdue since \(dueDay)")
                } else if c.allDay == true {
                    parts.append("all day")
                } else {
                    parts.append("due \(hhmm(dueDate, calendar))")
                }
            }
            parts.append(c.done ? "done" : "open")
            lines.append("- " + parts.joined(separator: ", "))
        }
        return SummaryPrompt(system: systemText, user: lines.joined(separator: "\n"))
    }

    private static func hhmm(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func weekday(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    /// One line, so a title can't add lines of its own to the prompt.
    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func quoted(_ title: String) -> String {
        "\"" + flat(title).replacingOccurrences(of: "\"", with: "'") + "\""
    }
}

enum SummaryDay {
    /// The local day as `YYYY-MM-DD`.
    static func string(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
