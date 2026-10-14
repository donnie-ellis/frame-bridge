import Hummingbird

/// `Photo` in the contract. `date` is a plain `YYYY-MM-DD`, `place` is omitted until geocoded.
public struct Photo: ResponseEncodable, Codable, Equatable, Sendable {
    public enum Orientation: String, Codable, Sendable { case l, p }

    public var id: String
    public var o: Orientation
    public var date: String
    public var place: String?
    public var tag: String
    public var fav: Bool
}
