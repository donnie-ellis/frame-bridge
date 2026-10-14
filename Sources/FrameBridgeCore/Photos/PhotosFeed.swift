import Foundation
import Logging

/// Where the assets come from. The real one is PhotoKit; tests use a stub.
protocol PhotoProvider: Sendable {
    func authorization() async -> FeedHealth.Authorization
    /// Why access can't be granted, when it can't be asked for (e.g. not run from the .app).
    func unavailableReason() async -> String?
    /// Throws `PhotoSourceError.albumNotFound` when there's no album with this title.
    func albumAssets(title: String) async throws -> [AssetValues]
    func oldestCreationDate() async -> Date?
    /// Images created in any of the ranges.
    func assets(in ranges: [DateInterval]) async throws -> [AssetValues]
}

extension PhotoProvider {
    func unavailableReason() async -> String? { nil }
}

protocol PlaceLookup: Sendable {
    func places(for ids: [String]) async -> [String: PlaceInfo]
}

enum PhotoSourceError: Error { case albumNotFound }

/// Holds the last built list. The request path only reads it (or builds it once if none exists),
/// and never geocodes.
public actor PhotosFeed {
    static let staleAfterSeconds = 172800
    static let deniedDetail = "switch FrameBridge on in System Settings → Privacy & Security → Photos"

    private let config: PhotosConfig
    private let provider: any PhotoProvider
    private let lookup: any PlaceLookup
    private let calendar: Calendar
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var photos: [Photo]?
    private var sampled: [AssetValues] = []
    private var knownPlaces: [String: PlaceInfo] = [:]
    private var lastBuilt: Date?
    private var lastError: String?

    init(config: PhotosConfig, provider: any PhotoProvider, lookup: any PlaceLookup, calendar: Calendar = .current, logger: Logger = Logger(label: "frame-bridge.photos"), now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.provider = provider
        self.lookup = lookup
        self.calendar = calendar
        self.logger = logger
        self.now = now
    }

    private static func serves(_ auth: FeedHealth.Authorization) -> Bool {
        auth == .authorized || auth == .limited
    }

    private func notGrantedDetail(_ auth: FeedHealth.Authorization) async -> String {
        if auth == .denied { return Self.deniedDetail }
        return await provider.unavailableReason() ?? "photos access not granted"
    }

    func list() async throws(APIError) -> [Photo] {
        let auth = await provider.authorization()
        guard Self.serves(auth) else { throw .sourceUnavailable(await notGrantedDetail(auth)) }
        if photos == nil || lastError != nil { _ = await build() }
        if let lastError { throw .sourceUnavailable(lastError) }
        guard let photos else { throw .sourceUnavailable("photos read failed") }
        return photos
    }

    /// Rebuilds the list and reports whether it differs from the previous build. The first build
    /// is the baseline and reports false.
    func rebuild() async -> Bool {
        let auth = await provider.authorization()
        guard Self.serves(auth) else { return false }
        let previous = photos
        guard await build(), let previous, let current = photos else { return false }
        return previous != current
    }

    /// Returns whether it succeeded. Keeps the previous list on failure.
    private func build() async -> Bool {
        let today = now()
        let seed = PhotoSampling.seed(forDay: PhotoMapping.localDate(today, placeTimeZone: nil, fallback: calendar.timeZone))
        do {
            let album = PhotoMapping.eligible(try await provider.albumAssets(title: config.album))
            var onThisDay: [AssetValues] = []
            if let oldest = await provider.oldestCreationDate() {
                let ranges = PhotoSampling.onThisDayRanges(today: today, oldestYear: calendar.component(.year, from: oldest), calendar: calendar)
                if !ranges.isEmpty { onThisDay = PhotoMapping.eligible(try await provider.assets(in: ranges)) }
            }
            let chosen = PhotoSampling.sample(album: album, onThisDay: onThisDay, seed: seed)
            let places = await lookup.places(for: chosen.map(\.id))
            photos = PhotoMapping.photos(chosen, places: places, macTimeZone: calendar.timeZone)
            sampled = chosen
            knownPlaces = places
            lastBuilt = today
            lastError = nil
            return true
        } catch PhotoSourceError.albumNotFound {
            logger.warning("photos album not found")
            lastError = "album not found"
        } catch {
            logger.warning("photos read failed")
            lastError = "photos read failed"
        }
        return false
    }

    /// Assets in the current list that have a location and no cache entry yet, for the geocode loop.
    func uncachedLocated() -> [AssetValues] {
        sampled.filter { $0.latitude != nil && $0.longitude != nil && knownPlaces[$0.id] == nil }
    }

    func health() async -> FeedHealth {
        let auth = await provider.authorization()
        let updated = lastBuilt.map { WireDate.string(from: $0) }
        func failed(_ detail: String) -> FeedHealth {
            FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: detail, updatedAt: updated, authorization: auth)
        }
        guard Self.serves(auth) else { return failed(await notGrantedDetail(auth)) }
        if let lastError { return failed(lastError) }
        guard photos != nil, updated != nil else { return failed("not built yet") }
        return FeedHealth(status: .ok, staleAfterSeconds: Self.staleAfterSeconds, updatedAt: updated, authorization: auth)
    }
}
