import CoreGraphics
import Foundation
import ImageIO
import Logging

/// What the configured room is playing, from polling its group coordinator. No UPnP event
/// subscriptions. Host, room, titles and art paths are private: never log them.
public actor NowPlayingFeed {
    static let staleAfterSeconds = 60

    private let config: SonosConfig
    private let client: SonosClient
    private let events: EventHub?
    private let timeZone: TimeZone
    private let logger: Logger
    private var value: NowPlaying?
    private var artPath: String?
    private var coordinator: String?
    private var lastSuccess: Date?
    private var lastError: String?

    init(config: SonosConfig, client: SonosClient, events: EventHub? = nil, timeZone: TimeZone = .current, logger: Logger = Logger(label: "frame-bridge.sonos")) {
        self.config = config
        self.client = client
        self.events = events
        self.timeZone = timeZone
        self.logger = logger
    }

    public init(config: SonosConfig, events: EventHub? = nil, logger: Logger) {
        self.init(config: config, client: SonosClient(transport: URLSessionSonosTransport()), events: events, logger: logger)
    }

    /// Reads the room once and returns how long to wait: 5 s while playing, else 15 s.
    func poll() async -> Duration {
        do {
            // Grouping changes the coordinator, so look it up every time.
            let host = try SonosMapping.coordinatorHost(topologyResponse: await client.zoneGroupState(host: config.host), room: config.room)
            let transport = try SonosMapping.transportState(response: await client.transportInfo(host: host))
            let position = try SonosMapping.position(response: await client.positionInfo(host: host))
            coordinator = host
            lastSuccess = Date()
            lastError = nil
            if transport == "TRANSITIONING", value != nil { return interval }
            let state = SonosMapping.state(transport, previous: value?.state)
            let mapped = SonosMapping.nowPlaying(room: config.room, state: state, trackURI: position.trackURI, didl: position.didl)
            let changed = mapped.value != value
            value = mapped.value
            artPath = mapped.artPath
            if changed { await events?.nowPlayingChanged(mapped.value) }
        } catch {
            let detail = Self.describe(error)
            if detail != lastError { logger.warning("sonos poll failed", metadata: ["reason": .string(detail)]) }
            lastError = detail
            value = nil
            artPath = nil
            coordinator = nil
        }
        return interval
    }

    private var interval: Duration { value?.state == .playing ? .seconds(5) : .seconds(15) }

    /// Short and free of hosts and room names: it goes to /healthz and the log.
    private static func describe(_ error: Error) -> String {
        switch error as? SonosError {
        case .roomNotFound: "room not found in Sonos topology"
        case .badResponse: "unexpected response"
        default: "speaker not reachable"
        }
    }

    func current() throws -> NowPlaying {
        guard let value else { throw APIError.sourceUnavailable(lastError ?? "no reading yet") }
        return value
    }

    /// The current track's art, resized. Only the speaker's own `/getaa` art.
    func artJPEG(size: ImageSize) async throws -> Data {
        guard value != nil, let coordinator else { throw APIError.sourceUnavailable(lastError ?? "no reading yet") }
        guard let artPath else { throw APIError.notFound }
        let fetched: (status: Int, data: Data)
        do {
            fetched = try await client.art(host: coordinator, path: artPath)
        } catch SonosError.badResponse {
            throw APIError.notFound
        } catch {
            throw APIError.sourceUnavailable("speaker not reachable")
        }
        guard (200..<300).contains(fetched.status),
              let source = CGImageSourceCreateWithData(fetched.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let jpeg = try? ImageSizing.jpeg(from: image, maxEdge: size.maxEdge)
        else { throw APIError.notFound }
        return jpeg
    }

    func health() -> FeedHealth {
        let updated = lastSuccess.map { WireDate.string(from: $0, timeZone: timeZone) }
        if let lastError {
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: lastError, updatedAt: updated)
        }
        guard let updated else {
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: "no reading yet")
        }
        return FeedHealth(status: .ok, staleAfterSeconds: Self.staleAfterSeconds, updatedAt: updated)
    }
}
