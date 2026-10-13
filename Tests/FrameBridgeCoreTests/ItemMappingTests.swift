import Foundation
import Testing

@testable import FrameBridgeCore

private let config = ShoppingConfig(
    list: "Shopping",
    stores: [Store(id: "grocer", name: "<store>"), Store(id: "costco", name: "<store>")],
    defaultStore: "grocer",
    storeKeywords: ["costco": ["paper towels"]],
    categories: ["Produce": ["apple", "avocados", "pineapple"], "Dairy & Eggs": ["butter", "eggs"], "Household": ["paper towels", "paper"]]
)
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func r(_ id: String, _ title: String, notes: String? = nil, done: Bool = false, completed: Date? = nil) -> ReminderValues {
    ReminderValues(id: id, title: title, notes: notes, isCompleted: done, completionDate: completed)
}

@Test(arguments: [
    ("3 avocados", 3, "avocados"), ("3x avocados", 3, "avocados"), ("3 x avocados", 3, "avocados"), ("3X avocados", 3, "avocados"),
    ("10 eggs", 10, "eggs"), ("0 apples", 1, "0 apples"), ("2", 1, "2"), ("  4 Milk ", 4, "Milk"),
    ("3 xylophones", 3, "xylophones"), ("Bananas", 1, "Bananas"), ("99999999999999999999 eggs", 1, "99999999999999999999 eggs"),
])
func quantityForms(title: String, qty: Int, name: String) {
    let q = ItemMapping.quantity(title)
    #expect(q.qty == qty && q.name == name)
}

@Test func categoryMatching() {
    func cat(_ t: String) -> ShoppingItem.Category { ItemMapping.item(r("1", t), config: config).cat }
    #expect(cat("Apple") == .produce)
    #expect(cat("pineapple") == .produce)
    #expect(cat("green apples") == .other)
    #expect(cat("Paper towels") == .household)
    #expect(cat("Unsalted BUTTER, 2 lb") == .dairyAndEggs)
    #expect(cat("widgets") == .other)
}

@Test func longestKeywordWinsAndTiesAreStable() {
    #expect(ItemMapping.match("paper towels", keywords: ["a": ["paper"], "b": ["paper towels"]]) == "b")
    #expect(ItemMapping.match("x y", keywords: ["b": ["x"], "a": ["y"]]) == "a")
}

@Test func storeKeywordOrDefault() {
    #expect(ItemMapping.item(r("1", "Paper towels"), config: config).store == "costco")
    #expect(ItemMapping.item(r("1", "Butter"), config: config).store == "grocer")
}

@Test func noteIsTrimmedAndOmittedWhenEmpty() throws {
    #expect(ItemMapping.item(r("1", "a", notes: "  hi \n"), config: config).note == "hi")
    #expect(ItemMapping.item(r("1", "a", notes: " \n"), config: config).note == nil)
    #expect(ItemMapping.item(r("1", "a"), config: config).note == nil)
    let json = String(data: try JSONEncoder().encode(ItemMapping.item(r("1", "a"), config: config)), encoding: .utf8)!
    #expect(!json.contains("null") && !json.contains("note"))
}

@Test func completedWindow() {
    let list = ItemMapping.list([
        r("old", "Old", done: true, completed: now.addingTimeInterval(-7 * 3600)),
        r("recent", "Recent", done: true, completed: now.addingTimeInterval(-5 * 3600)),
        r("nodate", "NoDate", done: true),
        r("open", "Open"),
    ], config: config, now: now)
    #expect(list.items.map(\.id) == ["open", "recent"])
    #expect(list.items[1].done)
}

@Test func orderIsIncompleteFirstThenNameThenId() {
    let list = ItemMapping.list([
        r("4", "apple", done: true, completed: now), r("3", "Banana"), r("2", "apple"), r("1", "apple"), r("5", "Cherry"),
    ], config: config, now: now)
    #expect(list.items.map(\.id) == ["1", "2", "3", "5", "4"])
}

@Test func everyStoreResolvesAndEncodingMatchesSpec() throws {
    let list = ItemMapping.list([r("1", "Butter", done: true, completed: now), r("2", "Paper towels")], config: config, now: now)
    let ids = Set(list.stores.map(\.id))
    #expect(list.items.allSatisfy { ids.contains($0.store) })
    let json = String(data: try JSONEncoder().encode(list), encoding: .utf8)!
    #expect(json.contains("\"cat\":\"Dairy & Eggs\""))
    #expect(!json.contains("null"))
    #expect(ShoppingItem.Category.allCases.map(\.rawValue) == ["Produce", "Bakery", "Meat & Fish", "Dairy & Eggs", "Pantry", "Frozen", "Snacks", "Household", "Other"])
}
