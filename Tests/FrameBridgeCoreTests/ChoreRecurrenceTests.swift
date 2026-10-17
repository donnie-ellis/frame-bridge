import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = ny
    c.firstWeekday = 1
    return c
}
// 2026-10-12 12:00 local, a Monday. Window: Oct 13 00:00 up to Oct 19 00:00.
private let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
private let window = ChoreMapping.upcomingWindow(now: now, calendar: cal)

private func dc(_ d: Int, _ h: Int? = 9, month: Int = 10, year: Int = 2026) -> DateComponents {
    DateComponents(year: year, month: month, day: d, hour: h, minute: h == nil ? nil : 0)
}

private func days(_ due: DateComponents, _ rule: ChoreRecurrence?, recurring: Bool = true, now: Date = now) -> [String] {
    let w = ChoreMapping.upcomingWindow(now: now, calendar: cal)
    return ChoreRecurrence.occurrences(due: due, rule: rule, isRecurring: recurring, window: w, calendar: cal).dates
        .map { WireDate.string(from: $0.date, timeZone: ny) }
}

private func rem(_ id: String, _ title: String = "T", due: DateComponents?, rule: ChoreRecurrence? = nil, recurring: Bool = false, done: Bool = false, notes: String? = nil) -> ChoreReminderValues {
    ChoreReminderValues(id: id, listId: "L", title: title, notes: notes, isCompleted: done, completionDate: nil, due: due, isRecurring: recurring, recurrence: rule)
}

@Test func upcomingWindowIsTomorrowThroughSixthDay() {
    #expect(window.lowerBound == cal.date(from: dc(13, nil)))
    #expect(window.upperBound == cal.date(from: dc(19, nil)))
}

@Test func daily_everyDayAfterTheAnchor() {
    let out = days(dc(12), ChoreRecurrence(frequency: .daily))
    #expect(out.count == 6 && out.first == "2026-10-13T09:00:00-04:00" && out.last == "2026-10-18T09:00:00-04:00")
    #expect(days(dc(12), ChoreRecurrence(frequency: .daily, interval: 3)) == ["2026-10-15T09:00:00-04:00", "2026-10-18T09:00:00-04:00"])
}

@Test func weekly_mondayAndThursday() {
    let rule = ChoreRecurrence(frequency: .weekly, daysOfTheWeek: [.init(weekday: 2, weekNumber: 0), .init(weekday: 5, weekNumber: 0)])
    #expect(days(dc(12), rule) == ["2026-10-15T09:00:00-04:00"])
    #expect(days(dc(8), rule) == ["2026-10-15T09:00:00-04:00"])
}

@Test func weekly_defaultsToTheAnchorWeekday() {
    #expect(days(dc(7), ChoreRecurrence(frequency: .weekly)) == ["2026-10-14T09:00:00-04:00"])
}

@Test func weekly_everyTwoWeeksAlignsToFirstDayOfTheWeek() {
    let wed = [ChoreRecurrence.Weekday(weekday: 4, weekNumber: 0)]
    // Anchor Wed Oct 7: Oct 14 is the next week (skipped), Oct 21 is the next turn.
    #expect(days(dc(7), ChoreRecurrence(frequency: .weekly, interval: 2, daysOfTheWeek: wed)).isEmpty)
    // Anchor Wed Sep 30: Oct 14 is two weeks on.
    #expect(days(dc(30, month: 9), ChoreRecurrence(frequency: .weekly, interval: 2, daysOfTheWeek: wed)) == ["2026-10-14T09:00:00-04:00"])
    // Anchor Sun Oct 11 with Sun and Tue, weeks starting Monday: Sunday ends its week, so Tue Oct 13 is a skipped week.
    let sunTue = [ChoreRecurrence.Weekday(weekday: 1, weekNumber: 0), .init(weekday: 3, weekNumber: 0)]
    let monday = ChoreRecurrence(frequency: .weekly, interval: 2, daysOfTheWeek: sunTue, firstDayOfTheWeek: 2)
    #expect(days(dc(11), monday).isEmpty)
    // Weeks starting Sunday: Tue Oct 13 is in the anchor's week.
    let sunday = ChoreRecurrence(frequency: .weekly, interval: 2, daysOfTheWeek: sunTue, firstDayOfTheWeek: 1)
    #expect(days(dc(11), sunday) == ["2026-10-13T09:00:00-04:00"])
    // firstDayOfTheWeek 0 follows the calendar's first weekday.
    var mondayCal = cal
    mondayCal.firstWeekday = 2
    let zero = ChoreRecurrence(frequency: .weekly, interval: 2, daysOfTheWeek: sunTue)
    let out = ChoreRecurrence.occurrences(due: dc(11), rule: zero, isRecurring: true, window: window, calendar: mondayCal).dates
    #expect(out.isEmpty)
    let sunOnly = ChoreRecurrence(frequency: .weekly, interval: 2, daysOfTheWeek: [.init(weekday: 3, weekNumber: 0)])
    // Tue only: the calendar's Sunday start keeps Oct 13 in the anchor's week, a Monday start skips it.
    #expect(ChoreRecurrence.occurrences(due: dc(11), rule: sunOnly, isRecurring: true, window: window, calendar: mondayCal).dates.isEmpty)
    #expect(days(dc(11), sunOnly).count == 1)
}

@Test func monthly_dayOfMonthAndShortMonths() {
    #expect(days(dc(15, month: 9), ChoreRecurrence(frequency: .monthly)) == ["2026-10-15T09:00:00-04:00"])
    let fifteenth = DateComponents(year: 2026, month: 9, day: 15, hour: 9, minute: 0)
    #expect(days(fifteenth, ChoreRecurrence(frequency: .monthly, daysOfTheMonth: [15, 17])) == ["2026-10-15T09:00:00-04:00", "2026-10-17T09:00:00-04:00"])
    // The 31st: October has it, November doesn't.
    let nov = cal.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 12))!
    #expect(days(dc(10, 31), ChoreRecurrence(frequency: .monthly), now: nov).isEmpty)
    let oct = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    #expect(days(dc(30, month: 9), ChoreRecurrence(frequency: .monthly, daysOfTheMonth: [31]), now: oct) == ["2026-10-31T09:00:00-04:00"])
    #expect(days(dc(30, month: 9), ChoreRecurrence(frequency: .monthly, daysOfTheMonth: [-1]), now: oct) == ["2026-10-31T09:00:00-04:00"])
}

@Test func monthly_everyTwoMonths() {
    let aug = DateComponents(year: 2026, month: 8, day: 15, hour: 9, minute: 0)
    let sep = DateComponents(year: 2026, month: 9, day: 15, hour: 9, minute: 0)
    #expect(days(aug, ChoreRecurrence(frequency: .monthly, interval: 2)) == ["2026-10-15T09:00:00-04:00"])
    #expect(days(sep, ChoreRecurrence(frequency: .monthly, interval: 2)).isEmpty)
}

@Test func yearly_sameMonthAndDay() {
    let last = DateComponents(year: 2025, month: 10, day: 15, hour: 9, minute: 0)
    #expect(days(last, ChoreRecurrence(frequency: .yearly)) == ["2026-10-15T09:00:00-04:00"])
    #expect(days(last, ChoreRecurrence(frequency: .yearly, interval: 2)).isEmpty)
}

@Test func endDateIsInclusiveByLocalDay() {
    let end = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 8))!
    let out = days(dc(12), ChoreRecurrence(frequency: .daily, end: .date(end)))
    #expect(out.count == 3 && out.last == "2026-10-15T09:00:00-04:00")
}

@Test func endCountCountsTheAnchor() {
    #expect(days(dc(12), ChoreRecurrence(frequency: .daily, end: .count(3))).count == 2)
    #expect(days(dc(12), ChoreRecurrence(frequency: .daily, end: .count(1))).isEmpty)
    // Occurrences before the window use up the count.
    #expect(days(dc(30, month: 9), ChoreRecurrence(frequency: .daily, end: .count(14))).count == 1)
}

@Test func dstChangeKeepsWallClockTime() {
    // Clocks go back on 2026-11-01.
    let sat = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
    let out = days(DateComponents(year: 2026, month: 10, day: 31, hour: 9, minute: 0), ChoreRecurrence(frequency: .daily), now: sat)
    #expect(out.first == "2026-11-01T09:00:00-05:00" && out.count == 6)
    let allDay = ChoreRecurrence.occurrences(due: dc(31, nil), rule: ChoreRecurrence(frequency: .daily), isRecurring: true, window: ChoreMapping.upcomingWindow(now: sat, calendar: cal), calendar: cal).dates
    #expect(allDay.map { WireDate.string(from: $0.date, timeZone: ny) }.first == "2026-11-01T00:00:00-04:00")
    #expect(allDay.map { WireDate.string(from: $0.date, timeZone: ny) }[1] == "2026-11-02T00:00:00-05:00")
    #expect(allDay.allSatisfy { $0.allDay })
}

@Test func overdueWeeklyChoreLandsInTheWindow() {
    let wed = ChoreRecurrence(frequency: .weekly, daysOfTheWeek: [.init(weekday: 4, weekNumber: 0)])
    #expect(days(dc(30, month: 9), wed) == ["2026-10-14T09:00:00-04:00"])
}

@Test func anchorInWindowIsListedOnce() {
    let out = days(dc(14), ChoreRecurrence(frequency: .daily))
    #expect(out.count == 5 && out.first == "2026-10-14T09:00:00-04:00")
    // Today's anchor belongs to /api/chores.
    #expect(!days(dc(12), ChoreRecurrence(frequency: .daily)).contains("2026-10-12T09:00:00-04:00"))
}

@Test func unexpandableRulesYieldTheAnchorOnly() {
    let r = ChoreRecurrence.occurrences(due: dc(14), rule: ChoreRecurrence(frequency: .monthly, unsupported: "setPositions"), isRecurring: true, window: window, calendar: cal)
    #expect(r.dates.count == 1 && r.unexpanded == "setPositions")
    let nth = ChoreRecurrence(frequency: .monthly, daysOfTheWeek: [.init(weekday: 2, weekNumber: 1)])
    #expect(ChoreRecurrence.occurrences(due: dc(14), rule: nth, isRecurring: true, window: window, calendar: cal).unexpanded == "rule parts")
    #expect(ChoreRecurrence.occurrences(due: dc(12), rule: nth, isRecurring: true, window: window, calendar: cal).dates.isEmpty)
    let old = ChoreRecurrence.occurrences(due: dc(1, month: 1, year: 2000), rule: ChoreRecurrence(frequency: .daily), isRecurring: true, window: window, calendar: cal)
    #expect(old.unexpanded == "anchor too old" && old.dates.isEmpty)
    #expect(ChoreRecurrence.occurrences(due: dc(14), rule: nil, isRecurring: true, window: window, calendar: cal).unexpanded == "no rule")
    #expect(ChoreRecurrence.occurrences(due: dc(14), rule: nil, isRecurring: false, window: window, calendar: cal).unexpanded == nil)
}

@Test func allDayOccurrencesAreMarked() {
    let r = ChoreRecurrence.occurrences(due: dc(12, nil), rule: ChoreRecurrence(frequency: .daily, end: .count(2)), isRecurring: true, window: window, calendar: cal)
    #expect(r.dates.count == 1 && r.dates[0].allDay)
}

// MARK: mapping

private func up(_ people: [(String, [ChoreReminderValues])]) -> (chores: [UpcomingChore], unexpanded: [(id: String, reason: String)]) {
    ChoreMapping.upcoming(byPerson: people.map { (who: $0.0, reminders: $0.1) }, now: now, calendar: cal)
}

@Test func upcomingSkipsCompletedUndatedTodayAndBeyond() {
    let out = up([("a", [rem("done", due: dc(14), done: true), rem("none", due: nil), rem("today", due: dc(12)),
                         rem("late", due: dc(19)), rem("ok", due: dc(13))])]).chores
    #expect(out.map(\.id) == ["ok/2026-10-13"])
}

@Test func upcomingIdsAreStablePerOccurrenceAndNotesTrimmed() {
    let r = rem("x", due: dc(13), rule: ChoreRecurrence(frequency: .daily), recurring: true, notes: "  hi \n")
    let first = up([("a", [r])]).chores
    #expect(first.map(\.id) == (13...18).map { "x/2026-10-\($0)" })
    #expect(first == up([("a", [r])]).chores)
    #expect(first[0].notes == "hi" && first[0].allDay == nil)
    #expect(up([("a", [rem("y", due: dc(13), notes: " ")])]).chores[0].notes == nil)
}

@Test func upcomingSortsByDueThenPersonThenTitle() {
    let out = up([("a", [rem("a2", "B", due: dc(14)), rem("a1", "A", due: dc(13, 18))]),
                  ("m", [rem("m1", "A", due: dc(14)), rem("m2", "A", due: dc(13, 18))])]).chores
    #expect(out.map(\.id) == ["a1/2026-10-13", "m2/2026-10-13", "a2/2026-10-14", "m1/2026-10-14"])
}

@Test func upcomingReportsUnexpandedRules() {
    let r = rem("x", due: dc(14), rule: ChoreRecurrence(frequency: .daily, unsupported: "setPositions"), recurring: true)
    let result = up([("a", [r])])
    #expect(result.chores.count == 1 && result.unexpanded.map(\.reason) == ["setPositions"])
}
