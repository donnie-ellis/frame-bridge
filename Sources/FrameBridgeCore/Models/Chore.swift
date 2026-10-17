import Hummingbird

/// `ChoreList` in the contract.
public struct ChoreList: ResponseEncodable, Codable, Equatable, Sendable {
    public var chores: [Chore]
}

/// `Chore` in the contract. `allDay` is `true` or omitted, never `false`.
public struct Chore: ResponseEncodable, Codable, Equatable, Sendable {
    public var id: String
    public var who: String
    public var title: String
    public var done: Bool
    public var due: String?
    public var allDay: Bool?
    public var notes: String?
}
