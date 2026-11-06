import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = ny
    return c
}
private func at(_ day: Int, _ h: Int = 0, _ m: Int = 0, _ s: Int = 0, month: Int = 10) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m, second: s))!
}

@Test func waitsForFiveAndThenRuns() {
    let schedule = SummarySchedule(now: at(12, 4, 59), timeZone: ny)
    #expect(schedule.nextAction(now: at(12, 4, 59), timeZone: ny) == .wait(until: at(12, 5)))
    #expect(schedule.nextAction(now: at(12, 5), timeZone: ny) == .generate)
}

@Test func startingLaterInTheDayRunsAtOnce() {
    let schedule = SummarySchedule(now: at(12, 14), timeZone: ny)
    #expect(schedule.nextAction(now: at(12, 14), timeZone: ny) == .generate)
}

@Test func aChangeBeforeFiveIsIgnored() {
    var schedule = SummarySchedule(now: at(12, 3), timeZone: ny)
    schedule.changed(at: at(12, 3), timeZone: ny)
    #expect(schedule.pendingChangeAt == nil)
    #expect(schedule.nextAction(now: at(12, 3, 0, 1), timeZone: ny) == .wait(until: at(12, 5)))
    schedule.attemptStarted(at: at(12, 5))
    #expect(schedule.nextAction(now: at(12, 5, 1), timeZone: ny) == .wait(until: at(13)))
}

@Test func aChangeWaitsForTheDebounceAndTheGap() {
    var schedule = SummarySchedule(now: at(12, 9), timeZone: ny)
    schedule.attemptStarted(at: at(12, 9))
    schedule.changed(at: at(12, 9, 2), timeZone: ny)
    // Two minutes after the run: the gap (5 min) is the longer wait.
    #expect(schedule.nextAction(now: at(12, 9, 2, 10), timeZone: ny) == .wait(until: at(12, 9, 5)))
    #expect(schedule.nextAction(now: at(12, 9, 5), timeZone: ny) == .generate)
    // A change long after the last run waits only the 10 s debounce.
    var later = SummarySchedule(now: at(12, 9), timeZone: ny)
    later.attemptStarted(at: at(12, 9))
    later.changed(at: at(12, 13), timeZone: ny)
    #expect(later.nextAction(now: at(12, 13, 0, 3), timeZone: ny) == .wait(until: at(12, 13, 0, 10)))
    later.changed(at: at(12, 13, 0, 8), timeZone: ny)
    #expect(later.nextAction(now: at(12, 13, 0, 10), timeZone: ny) == .wait(until: at(12, 13, 0, 18)))
}

@Test func anAttemptClearsThePendingChange() {
    var schedule = SummarySchedule(now: at(12, 9), timeZone: ny)
    schedule.attemptStarted(at: at(12, 9))
    schedule.changed(at: at(12, 12), timeZone: ny)
    schedule.attemptStarted(at: at(12, 12, 1))
    #expect(schedule.nextAction(now: at(12, 12, 5), timeZone: ny) == .wait(until: at(13)))
}

@Test func atMost24AttemptsADay() {
    var schedule = SummarySchedule(now: at(12, 5), timeZone: ny)
    for i in 0..<SummarySchedule.dailyCap { schedule.attemptStarted(at: at(12, 5, i * 5)) }
    #expect(schedule.attemptsToday == 24)
    #expect(schedule.nextAction(now: at(12, 8), timeZone: ny) == .wait(until: at(13)))
    schedule.changed(at: at(12, 8), timeZone: ny)
    #expect(schedule.nextAction(now: at(12, 8, 1), timeZone: ny) == .drop("daily summary limit reached"))
    schedule.dropped(now: at(12, 8, 1), timeZone: ny)
    #expect(schedule.nextAction(now: at(12, 8, 2), timeZone: ny) == .wait(until: at(13)))
}

@Test func midnightDropsAndResets() {
    var schedule = SummarySchedule(now: at(12, 5), timeZone: ny)
    for i in 0..<SummarySchedule.dailyCap { schedule.attemptStarted(at: at(12, 5, i)) }
    #expect(schedule.nextAction(now: at(13, 0, 0, 1), timeZone: ny) == .drop("not generated yet"))
    schedule.dropped(now: at(13, 0, 0, 1), timeZone: ny)
    #expect(schedule.attemptsToday == 0 && !schedule.ranToday && schedule.pendingChangeAt == nil)
    #expect(schedule.nextAction(now: at(13, 0, 0, 2), timeZone: ny) == .wait(until: at(13, 5)))
    #expect(schedule.nextAction(now: at(13, 5), timeZone: ny) == .generate)
}

@Test func theWaitNeverPassesMidnight() {
    var schedule = SummarySchedule(now: at(12, 23, 59, 0), timeZone: ny)
    schedule.attemptStarted(at: at(12, 23, 58))
    schedule.changed(at: at(12, 23, 59, 30), timeZone: ny)
    #expect(schedule.nextAction(now: at(12, 23, 59, 31), timeZone: ny) == .wait(until: at(13)))
}

@Test func daylightSavingDaysResetAtTheirLocalMidnight() {
    // 2026-11-01 has 25 hours in New York: midnight to midnight is not 24 h.
    var schedule = SummarySchedule(now: at(1, 5, month: 11), timeZone: ny)
    schedule.attemptStarted(at: at(1, 5, month: 11))
    #expect(schedule.nextAction(now: at(1, 23, 59, month: 11), timeZone: ny) == .wait(until: at(2, 0, month: 11)))
    #expect(schedule.nextAction(now: at(2, 0, 0, 1, month: 11), timeZone: ny) == .drop("not generated yet"))
    schedule.dropped(now: at(2, 0, 0, 1, month: 11), timeZone: ny)
    #expect(schedule.nextAction(now: at(2, 0, 0, 2, month: 11), timeZone: ny) == .wait(until: at(2, 5, month: 11)))
    // Spring forward (2026-03-08, 23 hours): 05:00 is still 05:00 local.
    let spring = SummarySchedule(now: at(8, 1, month: 3), timeZone: ny)
    #expect(spring.nextAction(now: at(8, 1, month: 3), timeZone: ny) == .wait(until: at(8, 5, month: 3)))
}
