import Foundation
import Logging

/// Reads and sets lights through the Hue Bridge. Keeps the last snapshot for health and for
/// looking up a light's room on PUT.
public actor LightsFeed {
    public static let staleAfterSeconds = 120

    private let config: HueConfig
    private let client: HueClient?
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var inFlight: Task<HueResources, any Error>?
    private var snapshot: HueResources?
    private var lastRead: Date?
    private var lastError: String?

    init(config: HueConfig, client: HueClient?, logger: Logger = Logger(label: "frame-bridge.lights"), now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.client = client
        self.logger = logger
        self.now = now
    }

    private static let notPaired = "not paired: run FrameBridge hue-pair <bridge ip>"

    func state() async throws(APIError) -> LightsState {
        LightsMapping.state(try await fetch(), sceneIcons: config.sceneIcons)
    }

    /// Concurrent callers share one fetch, so the bridge sees six requests, not six each.
    private func fetch() async throws(APIError) -> HueResources {
        guard let client else { throw .sourceUnavailable(Self.notPaired) }
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
            snapshot = resources
            lastRead = now()
            lastError = nil
            return resources
        } catch {
            inFlight = nil
            let apiError = Self.apiError(error, notFound: .sourceUnavailable("Hue Bridge not reachable"))
            lastError = apiError.detail
            throw apiError
        }
    }

    func set(id: String, patch: LightPatch) async throws(APIError) -> Light {
        guard let client else { throw .sourceUnavailable(Self.notPaired) }
        var resources = snapshot
        if resources == nil || !(resources?.lights.contains { $0.id == id } ?? false) {
            resources = try await fetch()
        }
        guard let resources, let known = resources.lights.first(where: { $0.id == id }),
              let room = LightsMapping.state(resources, sceneIcons: [:]).devices.first(where: { $0.id == id })?.room
        else { throw Self.noLight }
        do {
            try await client.putLight(id: id, body: LightsMapping.hueBody(for: patch, dimmable: known.dimming != nil))
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

    func setRoom(id: String, patch: LightPatch) async throws(APIError) -> Room {
        guard let client else { throw .sourceUnavailable(Self.notPaired) }
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
        guard let client else { throw .sourceUnavailable(Self.notPaired) }
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
        default: .sourceUnavailable("Hue Bridge not reachable")
        }
    }

    func health() -> FeedHealth {
        let stale = Self.staleAfterSeconds
        guard client != nil else { return FeedHealth(status: .error, staleAfterSeconds: stale, detail: "not paired") }
        let updated = lastRead.map { WireDate.string(from: $0) }
        if let lastError { return FeedHealth(status: .error, staleAfterSeconds: stale, detail: lastError, updatedAt: updated) }
        guard let updated else { return FeedHealth(status: .error, staleAfterSeconds: stale, detail: "not read yet") }
        return FeedHealth(status: .ok, staleAfterSeconds: stale, updatedAt: updated)
    }
}
