import Foundation

/// When the day summary is generated. A pure value: the service feeds it changes and the clock.
/// First run at 05:00 local (or at start, if later). After a calendar or chores change: wait for a
/// quiet 10 s and at least 5 min since the last attempt. At most 24 attempts a local day. At local
/// midnight everything resets and the old summary is dropped.
struct SummarySchedule: Equatable, Sendable {
    static let firstRunHour = 5
    static let debounce: TimeInterval = 10
    static let minimumGap: TimeInterval = 300
    static let dailyCap = 24

    enum Action: Equatable {
        case generate
        /// Drop the current summary, for this reason (the `/healthz` detail).
        case drop(String)
        case wait(until: Date)
    }

    private(set) var day: Date
    private(set) var attemptsToday = 0
    private(set) var lastAttempt: Date?
    private(set) var pendingChangeAt: Date?
    private(set) var ranToday = false

    init(now: Date, timeZone: TimeZone) {
        day = Self.calendar(timeZone).startOfDay(for: now)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func firstRun(of day: Date, _ calendar: Calendar) -> Date {
        calendar.date(bySettingHour: Self.firstRunHour, minute: 0, second: 0, of: day) ?? day.addingTimeInterval(Double(Self.firstRunHour) * 3600)
    }

    /// A change before 05:00 is ignored: the 05:00 run covers it.
    mutating func changed(at date: Date, timeZone: TimeZone) {
        let calendar = Self.calendar(timeZone)
        guard date >= firstRun(of: calendar.startOfDay(for: date), calendar) else { return }
        pendingChangeAt = date
    }

    func nextAction(now: Date, timeZone: TimeZone) -> Action {
        let calendar = Self.calendar(timeZone)
        if calendar.startOfDay(for: now) != day { return .drop("not generated yet") }
        let midnight = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let firstRun = firstRun(of: day, calendar)
        if now < firstRun { return .wait(until: firstRun) }
        if !ranToday { return .generate }
        guard let pending = pendingChangeAt else { return .wait(until: midnight) }
        if attemptsToday >= Self.dailyCap { return .drop("daily summary limit reached") }
        let ready = max(pending.addingTimeInterval(Self.debounce), (lastAttempt ?? pending).addingTimeInterval(Self.minimumGap))
        return now >= ready ? .generate : .wait(until: min(ready, midnight))
    }

    /// Records that an attempt starts now. A change that arrives during it counts for the next one.
    mutating func attemptStarted(at date: Date) {
        attemptsToday += 1
        lastAttempt = date
        ranToday = true
        pendingChangeAt = nil
    }

    /// Records that a `.drop` was carried out. After midnight this starts the new day.
    mutating func dropped(now: Date, timeZone: TimeZone) {
        let today = Self.calendar(timeZone).startOfDay(for: now)
        if today != day { self = SummarySchedule(now: now, timeZone: timeZone) } else { pendingChangeAt = nil }
    }
}
