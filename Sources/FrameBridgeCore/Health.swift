import Hummingbird

/// `Health` in the contract.
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
    public var updatedAt: String?
    public var authorization: Authorization?

    /// The spec's privacy authorization values (EventKit and PhotoKit).
    public enum Authorization: String, Codable, Sendable {
        case fullAccess, writeOnly, authorized, limited, denied, restricted, notDetermined
    }

    public init(status: Status, staleAfterSeconds: Int, detail: String? = nil, updatedAt: String? = nil, authorization: Authorization? = nil) {
        self.status = status
        self.staleAfterSeconds = staleAfterSeconds
        self.detail = detail
        self.updatedAt = updatedAt
        self.authorization = authorization
    }

    public static func notConfigured(staleAfterSeconds: Int) -> FeedHealth {
        FeedHealth(status: .error, staleAfterSeconds: staleAfterSeconds, detail: "not configured")
    }
}
