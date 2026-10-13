import Hummingbird

/// `Health` in the contract. `updatedAt` and `authorization` (photos) arrive with the feeds that set them.
public struct Health: ResponseEncodable, Decodable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, degraded }

    public struct Feeds: Codable, Equatable, Sendable {
        public var calendar: FeedHealth
        public var shopping: FeedHealth
        public var lights: FeedHealth
        public var weather: FeedHealth
        public var photos: FeedHealth
    }

    public var status: Status
    public var version: String
    public var feeds: Feeds

    public init(feeds: Feeds) {
        let all = [feeds.calendar, feeds.shopping, feeds.lights, feeds.weather, feeds.photos]
        self.status = all.contains { $0.status == .error } ? .degraded : .ok
        self.version = contractVersion
        self.feeds = feeds
    }
}

public struct FeedHealth: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, error }

    public var status: Status
    public var staleAfterSeconds: Int
    public var detail: String?

    public static func notImplemented(staleAfterSeconds: Int) -> FeedHealth {
        FeedHealth(status: .error, staleAfterSeconds: staleAfterSeconds, detail: "not implemented")
    }
}
