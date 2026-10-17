import Foundation

/// Finding the two halves of a completed recurring chore.
///
/// EventKit splits a recurring reminder when it is completed: the original keeps its id and moves
/// to the next due date, and a new completed, non-recurring copy takes the old due date. Un-checking
/// the copy would leave two open reminders.
///
/// Owner-approved exception to the EventKit write rule (#60, chat 2026-10-17): for the undo of a
/// recurring chore, in a configured chore list only, the source restores the original's due date
/// and then removes the completed copy. `recurringOriginal` is the only way into that path.
enum ChoreUndo {
    /// The copy EventKit made when `original` was completed at `savedAt`: another id, same list and
    /// title, completed, not recurring, completed within two minutes of the save. The closest wins.
    static func completedCopy(of original: ChoreReminderValues, among all: [ChoreReminderValues], savedAt: Date) -> ChoreReminderValues? {
        all.compactMap { r -> (ChoreReminderValues, TimeInterval)? in
            guard r.id != original.id, r.listId == original.listId, r.title == original.title,
                  r.isCompleted, !r.isRecurring, let done = r.completionDate else { return nil }
            let gap = abs(done.timeIntervalSince(savedAt))
            return gap <= 120 ? (r, gap) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    /// The open recurring reminder `copy` was split from, or nil (then the undo is a plain
    /// `isCompleted = false`). `copy` must be a completed, non-recurring reminder with a due date,
    /// completed today. There must be exactly one open recurring reminder in the same list with the
    /// same title and a later due date.
    static func recurringOriginal(for copy: ChoreReminderValues, among all: [ChoreReminderValues], now: Date, calendar: Calendar) -> ChoreReminderValues? {
        guard copy.isCompleted, !copy.isRecurring, let copyDue = copy.due.flatMap({ ChoreMapping.due($0, calendar: calendar)?.date }),
              let done = copy.completionDate, done >= calendar.startOfDay(for: now) else { return nil }
        let candidates = all.filter { r in
            guard r.id != copy.id, r.listId == copy.listId, r.title == copy.title, !r.isCompleted, r.isRecurring,
                  let due = r.due.flatMap({ ChoreMapping.due($0, calendar: calendar)?.date }) else { return false }
            return due > copyDue
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
