import Hummingbird

/// `Photo` in the contract. `date` is a plain `YYYY-MM-DD`, `place` and `focus` are omitted until known.
public struct Photo: ResponseEncodable, Codable, Equatable, Sendable {
    public enum Orientation: String, Codable, Sendable { case l, p }

    public var id: String
    public var o: Orientation
    public var date: String
    public var place: String?
    public var tag: String
    public var fav: Bool
    public var focus: PhotoFocus?
}

/// `PhotoFocus` in the contract: fractions of the image, top-left origin, already padded.
public struct PhotoFocus: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
}
