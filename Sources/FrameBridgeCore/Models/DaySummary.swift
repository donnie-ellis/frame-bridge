import Hummingbird

/// `DaySummary` in the contract. `date` is the local day (`YYYY-MM-DD`), `text` is 1 to 400 characters.
public struct DaySummary: ResponseEncodable, Codable, Equatable, Sendable {
    public var date: String
    public var text: String
}
