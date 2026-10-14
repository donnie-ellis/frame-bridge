import Foundation

/// The parts of an EKReminder the mapping needs, as plain values.
struct ReminderValues: Sendable, Equatable {
    var id: String
    var title: String
    var notes: String?
    var isCompleted: Bool
    var completionDate: Date?
}

/// Reminder values -> wire models. Pure, so the rules are testable without EventKit.
enum ItemMapping {
    static let completedWindow: TimeInterval = 6 * 3600

    // "3 avocados", "3x avocados", "3 x avocados"; "3 xylophones" keeps "xylophones" as the name.
    private static let leadingQuantity = try! NSRegularExpression(pattern: #"^([0-9]+)(?:\s*[xX])?\s+(\S.*)$"#)

    /// Leading number -> qty and the rest as name. No number, 0, a bare number or overflow: qty 1, title unchanged.
    static func quantity(_ title: String) -> (qty: Int, name: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = leadingQuantity.firstMatch(in: trimmed, range: range),
              let numRange = Range(m.range(at: 1), in: trimmed),
              let nameRange = Range(m.range(at: 2), in: trimmed),
              let qty = Int(trimmed[numRange]), qty >= 1
        else { return (1, trimmed) }
        return (qty, String(trimmed[nameRange]))
    }

    /// The key whose keywords match `text` as a whole word (or a simple plural of it), case-insensitively. The longest keyword wins;
    /// ties go to the smaller key, then the smaller keyword.
    static func match(_ text: String, keywords: [String: [String]]) -> String? {
        let haystack = text.lowercased()
        var best: (key: String, keyword: String)?
        for key in keywords.keys.sorted() {
            for keyword in keywords[key, default: []].sorted() {
                let k = keyword.lowercased()
                guard !k.isEmpty, pluralForms(k).contains(where: { containsWholeWord(haystack, $0) }) else { continue }
                if best == nil || k.count > best!.keyword.count { best = (key, k) }
            }
        }
        return best?.key
    }

    // +s, +es, and consonant+y -> ies. Multi-word keywords pluralize their last word.
    private static func pluralForms(_ k: String) -> [String] {
        var forms = [k, k + "s", k + "es"]
        if k.hasSuffix("y"), let prev = k.dropLast().last, prev.isLetter, !"aeiou".contains(prev) {
            forms.append(k.dropLast() + "ies")
        }
        return forms
    }

    private static func containsWholeWord(_ haystack: String, _ word: String) -> Bool {
        var from = haystack.startIndex
        while let r = haystack.range(of: word, range: from..<haystack.endIndex) {
            let before = r.lowerBound == haystack.startIndex || !isWordChar(haystack[haystack.index(before: r.lowerBound)])
            let after = r.upperBound == haystack.endIndex || !isWordChar(haystack[r.upperBound])
            if before && after { return true }
            from = haystack.index(after: r.lowerBound)
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func item(_ r: ReminderValues, config: ShoppingConfig) -> ShoppingItem {
        let (qty, name) = quantity(r.title)
        let cat = match(name, keywords: config.categories).flatMap(ShoppingItem.Category.init(rawValue:)) ?? .other
        let store = match(name, keywords: config.storeKeywords) ?? config.defaultStore
        let note = r.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShoppingItem(id: r.id, name: name, note: note?.isEmpty == false ? note : nil, done: r.isCompleted, qty: qty, cat: cat, store: store)
    }

    /// Open items, plus items completed within the window, incomplete first, then by name.
    static func list(_ reminders: [ReminderValues], config: ShoppingConfig, now: Date, window: TimeInterval = completedWindow) -> ShoppingList {
        let cutoff = now.addingTimeInterval(-window)
        let kept = reminders.filter { r in
            guard r.isCompleted else { return true }
            guard let done = r.completionDate else { return false }
            return done >= cutoff
        }
        let items = kept.map { item($0, config: config) }.sorted { a, b in
            if a.done != b.done { return !a.done }
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.id < b.id
        }
        return ShoppingList(stores: config.stores, items: items)
    }
}
