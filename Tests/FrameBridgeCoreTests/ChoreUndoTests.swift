import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = ny
    return c
}
private let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!

private func due(_ day: Int) -> DateComponents { DateComponents(year: 2026, month: 10, day: day, hour: 9, minute: 0) }

private func v(_ id: String, title: String = "T", list: String = "L", done: Bool = false, completed: Date? = nil, due d: DateComponents? = nil, recurring: Bool = false) -> ChoreReminderValues {
    ChoreReminderValues(id: id, listId: list, title: title, notes: nil, isCompleted: done, completionDate: completed, due: d, isRecurring: recurring)
}

private let copy = v("copy", done: true, completed: now.addingTimeInterval(-60), due: due(12))
private let original = v("orig", due: due(13), recurring: true)

@Test func completedCopyIsFoundNearTheSave() {
    let original = v("orig", due: due(13), recurring: true)
    let far = v("far", done: true, completed: now.addingTimeInterval(-500), due: due(12))
    let near = v("near", done: true, completed: now.addingTimeInterval(-10), due: due(12))
    let nearer = v("nearer", done: true, completed: now.addingTimeInterval(5), due: due(12))
    #expect(ChoreUndo.completedCopy(of: original, among: [far, near, nearer], savedAt: now)?.id == "nearer")
    #expect(ChoreUndo.completedCopy(of: original, among: [far], savedAt: now) == nil)
}

@Test func completedCopyNeedsSameListTitleAndNotRecurring() {
    let o = v("orig", due: due(13), recurring: true)
    let t = now
    #expect(ChoreUndo.completedCopy(of: o, among: [v("c", list: "M", done: true, completed: t)], savedAt: now) == nil)
    #expect(ChoreUndo.completedCopy(of: o, among: [v("c", title: "U", done: true, completed: t)], savedAt: now) == nil)
    #expect(ChoreUndo.completedCopy(of: o, among: [v("c", done: true, completed: t, recurring: true)], savedAt: now) == nil)
    #expect(ChoreUndo.completedCopy(of: o, among: [v("c", done: false, completed: t)], savedAt: now) == nil)
    #expect(ChoreUndo.completedCopy(of: o, among: [v("orig", done: true, completed: t)], savedAt: now) == nil)
}

@Test func originalFoundWithExactlyOneLaterOpenRecurringSameTitleSameList() {
    #expect(ChoreUndo.recurringOriginal(for: copy, among: [copy, original], now: now, calendar: cal)?.id == "orig")
}

@Test func originalIsNilInEveryOtherCase() {
    func find(_ c: ChoreReminderValues, _ others: [ChoreReminderValues]) -> ChoreReminderValues? {
        ChoreUndo.recurringOriginal(for: c, among: others, now: now, calendar: cal)
    }
    let second = v("orig2", due: due(14), recurring: true)
    #expect(find(copy, [original, second]) == nil)
    let yesterday = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 20))!
    #expect(find(v("copy", done: true, completed: yesterday, due: due(12)), [original]) == nil)
    #expect(find(v("copy", done: true, completed: now, due: due(12), recurring: true), [original]) == nil)
    #expect(find(v("copy", done: true, completed: now), [original]) == nil)
    #expect(find(copy, [v("orig", due: due(12), recurring: true)]) == nil)
    #expect(find(copy, [v("orig", due: due(11), recurring: true)]) == nil)
    #expect(find(copy, [v("orig", due: due(13))]) == nil)
    #expect(find(copy, [v("orig", title: "U", due: due(13), recurring: true)]) == nil)
    #expect(find(copy, [v("orig", list: "M", due: due(13), recurring: true)]) == nil)
    #expect(find(v("copy", done: false, due: due(12)), [original]) == nil)
}
