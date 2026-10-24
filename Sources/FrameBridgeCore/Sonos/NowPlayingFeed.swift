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
    private let externalArt: any ExternalArtTransport
    private let events: EventHub?
    private let timeZone: TimeZone
    private let logger: Logger
    private var value: NowPlaying?
    private var art: (full: Data, half: Data)?
    // The art source last tried, so a failed fetch isn't retried every poll for the same track.
    private var artAttempted: ArtSource?
    private var artTask: Task<Void, Never>?
    private var coordinator: String?
    private var lastSuccess: Date?
    private var lastError: String?

    init(config: SonosConfig, client: SonosClient, externalArt: any ExternalArtTransport, events: EventHub? = nil, timeZone: TimeZone = .current, logger: Logger = Logger(label: "frame-bridge.sonos")) {
        self.config = config
        self.client = client
        self.externalArt = externalArt
        self.events = events
        self.timeZone = timeZone
        self.logger = logger
    }

    public init(config: SonosConfig, events: EventHub? = nil, logger: Logger) {
        self.init(config: config, client: SonosClient(transport: URLSessionSonosTransport()), externalArt: URLSessionExternalArtTransport(), events: events, logger: logger)
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
            var mapped = SonosMapping.nowPlaying(room: config.room, state: state, trackURI: position.trackURI, didl: position.didl)
            // `art: true` goes out only once the image is in memory. The track goes out first with
            // `art: false`, and a second event follows when the background fetch succeeds.
            if let source = mapped.artSource {
                if source != artAttempted {
                    artAttempted = source
                    art = nil
                    let stale = artTask
                    stale?.cancel()
                    // Awaits the cancelled fetch, so a stale one has finished before this one reports.
                    artTask = Task {
                        let result = await fetchArt(host: host, source: source)
                        await stale?.value
                        guard !Task.isCancelled else { return }
                        await artArrived(source, result)
                    }
                }
            } else {
                artTask?.cancel()
                artTask = nil
                art = nil
                artAttempted = nil
            }
            if mapped.value.art == true, art == nil { mapped.value.art = false }
            let changed = mapped.value != value
            value = mapped.value
            if changed { await events?.nowPlayingChanged(mapped.value) }
        } catch {
            let detail = Self.describe(error)
            if detail != lastError { logger.warning("sonos poll failed", metadata: ["reason": .string(detail)]) }
            lastError = detail
            value = nil
            artTask?.cancel()
            artTask = nil
            art = nil
            artAttempted = nil
            coordinator = nil
        }
        return interval
    }

    private func artArrived(_ source: ArtSource, _ result: (full: Data, half: Data)?) async {
        guard artAttempted == source, value != nil else { return }
        art = result
        if result != nil, value?.art == false {
            value?.art = true
            if let value { await events?.nowPlayingChanged(value) }
        }
    }

    /// Test hook: waits for the latest art fetch to finish.
    func artSettled() async { await artTask?.value }

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

    /// Once per track change. A failure is not an outage: the track just has no art.
    private func fetchArt(host: String, source: ArtSource) async -> (full: Data, half: Data)? {
        let data: Data?
        switch source {
        case .speaker(let path):
            if let fetched = try? await client.art(host: host, path: path), (200..<300).contains(fetched.status) {
                data = fetched.data
            } else {
                data = nil
            }
        case .external(let url):
            data = try? await externalArt.get(url)
        }
        if let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let full = try? ImageSizing.jpeg(from: image, maxEdge: ImageSize.full.maxEdge),
           let half = try? ImageSizing.jpeg(from: image, maxEdge: ImageSize.half.maxEdge) {
            return (full, half)
        }
        logger.debug("sonos art unavailable")
        return nil
    }

    /// The current track's art, from memory. Never contacts the speaker.
    func artJPEG(size: ImageSize) throws -> Data {
        guard let value, coordinator != nil else { throw APIError.sourceUnavailable(lastError ?? "no reading yet") }
        guard value.art == true, let art else { throw APIError.notFound }
        return size == .half ? art.half : art.full
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
