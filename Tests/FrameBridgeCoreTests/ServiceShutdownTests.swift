import Foundation
import Logging
import ServiceLifecycle
import Testing

@testable import FrameBridgeCore

private struct FailingFetcher: ForecastFetching {
    func fetchForecast() async throws -> Data { throw ForecastFetchError.network(-1009) }
}

/// Runs the service in a group, asks for a graceful shutdown mid-sleep, and expects a clean return.
private func shutsDownCleanly(_ service: some Service) async throws {
    let group = ServiceGroup(configuration: .init(services: [service], logger: Logger(label: "test")))
    try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { try await group.run() }
        try await Task.sleep(for: .milliseconds(50))
        await group.triggerGracefulShutdown()
        try await tasks.next()
    }
}

@Test(.timeLimit(.minutes(1)))
func weatherRefreshServiceStopsOnGracefulShutdown() async throws {
    let store = WeatherStore(fetcher: FailingFetcher(), logger: Logger(label: "test"))
    try await shutsDownCleanly(WeatherRefreshService(store: store, interval: .seconds(3600)))
}

@Test(.timeLimit(.minutes(1)))
func eventPingServiceStopsOnGracefulShutdownAndFinishesStreams() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    try await shutsDownCleanly(EventPingService(hub: hub, interval: .seconds(60)))
    var received: [String] = []
    for await message in stream { received.append(message) }
    #expect(!received.contains { $0.contains("ping") })
}

@Test(.timeLimit(.minutes(1)))
func nowPlayingServiceStopsOnGracefulShutdown() async throws {
    let feed = NowPlayingFeed(
        config: SonosConfig(host: SonosFixture.hostA, room: "Room A"),
        client: SonosClient(transport: StubSonosTransport()),
        externalArt: StubExternalArt(),
        logger: Logger(label: "test"))
    try await shutsDownCleanly(NowPlayingService(feed: feed))
}
