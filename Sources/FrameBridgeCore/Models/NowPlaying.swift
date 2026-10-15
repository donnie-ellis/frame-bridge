import Hummingbird

/// `NowPlaying` in the contract. Optional fields are omitted when unknown, never `null`.
public struct NowPlaying: ResponseEncodable, Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case playing, paused, stopped }
    public enum Source: String, Codable, Sendable { case music, tv, lineIn }

    public var room: String
    public var state: State
    public var title: String?
    public var artist: String?
    public var album: String?
    public var art: Bool?
    public var source: Source?

    public init(room: String, state: State, title: String? = nil, artist: String? = nil, album: String? = nil, art: Bool? = nil, source: Source? = nil) {
        self.room = room
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.art = art
        self.source = source
    }
}
