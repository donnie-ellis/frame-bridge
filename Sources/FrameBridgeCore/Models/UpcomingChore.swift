import Hummingbird

/// `UpcomingChoreList` in the contract.
public struct UpcomingChoreList: ResponseEncodable, Codable, Equatable, Sendable {
    public var chores: [UpcomingChore]
}

/// `UpcomingChore` in the contract: one occurrence, read only, so no `done`. `allDay` is `true` or omitted.
public struct UpcomingChore: ResponseEncodable, Codable, Equatable, Sendable {
    public var id: String
    public var who: String
    public var title: String
    public var due: String
    public var allDay: Bool?
    public var notes: String?
}
