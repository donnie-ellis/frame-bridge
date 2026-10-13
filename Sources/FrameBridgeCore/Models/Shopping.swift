import Hummingbird

/// `ShoppingList` in the contract.
public struct ShoppingList: ResponseEncodable, Codable, Equatable, Sendable {
    public var stores: [Store]
    public var items: [ShoppingItem]
}

/// `Store` in the contract.
public struct Store: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `ShoppingItem` in the contract.
public struct ShoppingItem: Codable, Equatable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case produce = "Produce"
        case bakery = "Bakery"
        case meatAndFish = "Meat & Fish"
        case dairyAndEggs = "Dairy & Eggs"
        case pantry = "Pantry"
        case frozen = "Frozen"
        case snacks = "Snacks"
        case household = "Household"
        case other = "Other"
    }

    public var id: String
    public var name: String
    public var note: String?
    public var done: Bool
    public var qty: Int
    public var cat: Category
    public var store: String
}
