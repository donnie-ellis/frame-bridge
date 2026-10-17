import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = ny
    return c
}
// 2026-10-12 12:00 local
private let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!

private func dc(_ d: Int, _ h: Int? = nil, month: Int = 10) -> DateComponents {
    DateComponents(year: 2026, month: month, day: d, hour: h, minute: h == nil ? nil : 0)
}

private func r(_ id: String, _ title: String = "T", due: DateComponents? = nil, done: Bool = false, completed: Date? = nil, notes: String? = nil) -> ChoreReminderValues {
    ChoreReminderValues(id: id, listId: "L", title: title, notes: notes, isCompleted: done, completionDate: completed, due: due, isRecurring: false)
}

private func list(_ people: [(String, [ChoreReminderValues])]) -> [Chore] {
    ChoreMapping.list(byPerson: people.map { (who: $0.0, reminders: $0.1) }, now: now, calendar: cal)
}

@Test func timedDueKeepsLocalOffset() {
    let c = ChoreMapping.chore(r("1", due: dc(12, 18)), who: "a", calendar: cal)
    #expect(c.due == "2026-10-12T18:00:00-04:00" && c.allDay == nil && c.done == false)
}

@Test func allDayDueIsLocalMidnight() {
    let c = ChoreMapping.chore(r("1", due: dc(12)), who: "a", calendar: cal)
    #expect(c.due == "2026-10-12T00:00:00-04:00" && c.allDay == true)
}

@Test func noDueOmitsDueAndAllDay() throws {
    let c = ChoreMapping.chore(r("1"), who: "a", calendar: cal)
    #expect(c.due == nil && c.allDay == nil)
    let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
    #expect(!json.contains("null") && !json.contains("due") && !json.contains("allDay") && !json.contains("notes"))
}

@Test func notesAreTrimmedAndOmittedWhenEmpty() {
    #expect(ChoreMapping.chore(r("1", notes: "  Floor \n"), who: "a", calendar: cal).notes == "Floor")
    #expect(ChoreMapping.chore(r("1", notes: " \n"), who: "a", calendar: cal).notes == nil)
}

@Test func keepsOverdueUndatedAndToday_dropsLater() {
    let kept = list([("a", [
        r("overdue", due: dc(10, 9)), r("today", due: dc(12, 23)), r("undated"),
        r("tomorrow", due: dc(13)), r("tomorrow9", due: dc(13, 9)),
    ])])
    #expect(kept.map(\.id) == ["overdue", "today", "undated"])
}

@Test func completedKeptOnlyWhenCompletedToday() {
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8))!
    let yesterday = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 23, minute: 59))!
    let out = list([("a", [
        r("d1", done: true, completed: today), r("d2", done: true, completed: yesterday), r("d3", done: true),
        r("d4", due: dc(20), done: true, completed: today),
    ])])
    #expect(out.map(\.id) == ["d4", "d1"])
    #expect(out.allSatisfy { $0.done })
}

@Test func sortsByPersonThenDueUndatedLastThenTitleThenId() {
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8))!
    let out = list([
        ("a", [r("u", "B"), r("t2", "B", due: dc(12, 9)), r("t1", "A", due: dc(12, 9)), r("e", due: dc(11, 9)), r("done", due: dc(12, 7), done: true, completed: today)]),
        ("b", [r("z2", "Z", due: dc(12, 1)), r("z1", "Z", due: dc(12, 1))]),
    ])
    #expect(out.map(\.id) == ["e", "done", "t1", "t2", "u", "z1", "z2"])
    #expect(out.map(\.who) == ["a", "a", "a", "a", "a", "b", "b"])
}
