import Hummingbird

/// `Event` in the contract. `travel` is reserved for a later source, so it isn't here.
public struct Event: ResponseEncodable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: String
    public var end: String
    public var allDay: Bool
    public var people: [String]
    public var loc: String?
    public var notes: String?
}
