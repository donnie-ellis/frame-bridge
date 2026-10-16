import Foundation
import Logging

/// Reads and sets lights through the Hue Bridge. While the event stream is connected, the cached
/// snapshot is kept current from the stream and served without asking the bridge. Changes to it
/// go out as SSE events.
public actor LightsFeed {
    public static let staleAfterSeconds = 120

    private let config: HueConfig
    private var client: HueClient?
    /// True until the Keychain read finishes: it can wait on a prompt, so "not paired" would be wrong.
    private var readingCredentials: Bool
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var inFlight: Task<HueResources, any Error>?
    private var snapshot: HueResources?
    private var lastRead: Date?
    private var connected = false
    private var lastStreamError: String?
    private let events: EventHub?
    private let resyncDebouncer: EventStoreDebouncer
    private var resyncSubscribed = false

    init(config: HueConfig, client: HueClient?, logger: Logger = Logger(label: "frame-bridge.lights"), now: @escaping @Sendable () -> Date = Date.init,
         events: EventHub? = nil, resyncInterval: Duration = .seconds(2), readingCredentials: Bool = false) {
        self.config = config
        self.client = client
        self.readingCredentials = readingCredentials
        self.logger = logger
        self.now = now
        self.events = events
        self.resyncDebouncer = EventStoreDebouncer(interval: resyncInterval)
    }

    private static let notPaired = "not paired: run FrameBridge hue-pair <bridge ip>"
    static let waitingForKeychain = "waiting for the Keychain: allow FrameBridge if the Mac shows a prompt"

    private var notPairedDetail: String { readingCredentials ? Self.waitingForKeychain : Self.notPaired }

    /// The Keychain read finished: `client` is nil when there are no credentials.
    func credentialsRead(_ client: HueClient?) {
        self.client = client
        readingCredentials = false
    }

    func state() async throws(APIError) -> LightsState {
        if connected, let snapshot { return LightsMapping.state(snapshot, sceneIcons: config.sceneIcons) }
        return LightsMapping.state(try await fetch(), sceneIcons: config.sceneIcons)
    }

    /// The only writer of the snapshot. Sends the in-place events for what changed, then one
    /// `lights` notice when the set of ids changed. The first read sends nothing.
    private func replaceCache(_ new: HueResources) async {
        let old = snapshot
        snapshot = new
        lastRead = now()
        guard let old, let events else { return }
        let before = LightsMapping.state(old, sceneIcons: config.sceneIcons)
        let after = LightsMapping.state(new, sceneIcons: config.sceneIcons)
        for event in HueEventMerge.events(from: before, to: after) { await events.send(event) }
        if HueEventMerge.idsChanged(before, after) { await events.lightsChanged() }
    }

    /// One full read after the stream (re)connects. Not connected until it succeeds.
    func streamOpened() async throws {
        guard let client else { throw HueClientError.unreachable }
        await replaceCache(try await client.resources())
        connected = true
        lastStreamError = nil
    }

    func streamClosed(reason: String) {
        connected = false
        lastStreamError = reason
    }

    /// One stream message: merge it into a copy of the cache. When the cache can't follow, one
    /// debounced full read follows the burst.
    func apply(payload: String) async {
        guard connected, var copy = snapshot else { return }
        let needsResync = HueEventMerge.apply(HueEventDecoder.batches(in: payload), to: &copy)
        if copy != snapshot { await replaceCache(copy) }
        if needsResync {
            if !resyncSubscribed {
                resyncSubscribed = true
                await resyncDebouncer.subscribe { [weak self] in await self?.resync() }
            }
            await resyncDebouncer.poke()
        }
    }

    private func resync() async {
        guard connected, let client else { return }
        do {
            await replaceCache(try await client.resources())
        } catch {
            logger.warning("hue resync failed", metadata: HueFailure.logMetadata(for: error))
        }
    }

    /// Concurrent callers share one fetch, so the bridge sees six requests, not six each.
    private func fetch() async throws(APIError) -> HueResources {
        guard let client else { throw .sourceUnavailable(notPairedDetail) }
        let task: Task<HueResources, any Error>
        if let inFlight {
            task = inFlight
        } else {
            task = Task { try await client.resources() }
            inFlight = task
        }
        do {
            let resources = try await task.value
            inFlight = nil
            await replaceCache(resources)
            return resources
        } catch {
            inFlight = nil
            throw Self.apiError(error, notFound: .sourceUnavailable("Hue Bridge not reachable"))
        }
    }

    func set(id: String, patch: LightPatch) async throws(APIError) -> Light {
        guard let client else { throw .sourceUnavailable(notPairedDetail) }
        var resources = snapshot
        if resources == nil || !(resources?.lights.contains { $0.id == id } ?? false) {
            resources = try await fetch()
        }
        guard let resources, let known = resources.lights.first(where: { $0.id == id }),
              let room = LightsMapping.state(resources, sceneIcons: [:]).devices.first(where: { $0.id == id })?.room
        else { throw Self.noLight }
        let body = try LightsMapping.hueBody(for: patch, light: known)
        do {
            try await client.putLight(id: id, body: body)
            let updated = try await client.light(id: id)
            return LightsMapping.light(updated, room: room)
        } catch {
            throw Self.apiError(error, notFound: Self.noLight)
        }
    }

    /// The snapshot, or a fresh read when there is none or `known` doesn't find the id in it.
    private func resources(containing known: (HueResources) -> Bool) async throws(APIError) -> HueResources {
        if let snapshot, known(snapshot) { return snapshot }
        return try await fetch()
    }

    func setRoom(id: String, patch: RoomPatch) async throws(APIError) -> Room {
        guard let client else { throw .sourceUnavailable(notPairedDetail) }
        let resources = try await resources { LightsMapping.groupedLightID(ofGroup: id, in: $0) != nil }
        guard let groupedID = LightsMapping.groupedLightID(ofGroup: id, in: resources),
              let grouped = resources.groupedLights.first(where: { $0.id == groupedID }),
              let room = LightsMapping.state(resources, sceneIcons: [:]).rooms.first(where: { $0.id == id })
        else { throw Self.noRoom }
        do {
            try await client.putGroupedLight(id: groupedID, body: LightsMapping.hueBody(for: patch, dimmable: grouped.dimming != nil))
            let updated = try await client.groupedLight(id: groupedID)
            return LightsMapping.room(room, after: updated)
        } catch {
            throw Self.apiError(error, notFound: Self.noRoom)
        }
    }

    func recallScene(id: String) async throws(APIError) -> Scene {
        guard let client else { throw .sourceUnavailable(notPairedDetail) }
        let resources = try await resources { r in LightsMapping.state(r, sceneIcons: [:]).scenes.contains { $0.id == id } }
        guard var scene = LightsMapping.state(resources, sceneIcons: config.sceneIcons).scenes.first(where: { $0.id == id })
        else { throw Self.noScene }
        do {
            try await client.putScene(id: id, body: LightsMapping.recallBody)
        } catch {
            throw Self.apiError(error, notFound: Self.noScene)
        }
        scene.active = true
        return scene
    }

    private static let noRoom = APIError(error: "not_found", detail: "no room with that id", status: .notFound)
    private static let noScene = APIError(error: "not_found", detail: "no scene with that id", status: .notFound)
    private static let noLight = APIError(error: "not_found", detail: "no light with that id", status: .notFound)

    private static func apiError(_ error: any Error, notFound: APIError) -> APIError {
        switch error as? HueClientError {
        case .notFound: notFound
        case .unauthorized: .sourceUnavailable("Hue application key rejected: run hue-pair")
        case .pinMismatch: .sourceUnavailable("Hue Bridge certificate doesn't match the pin: run hue-pair")
        default: .sourceUnavailable("Hue Bridge not reachable")
        }
    }

    func health() -> FeedHealth {
        let stale = Self.staleAfterSeconds
        guard client != nil else { return FeedHealth(status: .error, staleAfterSeconds: stale, detail: readingCredentials ? Self.waitingForKeychain : "not paired") }
        if connected { return FeedHealth(status: .ok, staleAfterSeconds: stale, updatedAt: WireDate.string(from: now())) }
        return FeedHealth(status: .error, staleAfterSeconds: stale, detail: lastStreamError ?? "Hue event stream not connected",
                          updatedAt: lastRead.map { WireDate.string(from: $0) })
    }
}
