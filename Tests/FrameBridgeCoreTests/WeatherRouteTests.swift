import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private actor StubFetcher: ForecastFetching {
    private var result: Result<Data, Error>
    init(_ result: Result<Data, Error>) { self.result = result }
    func set(_ result: Result<Data, Error>) { self.result = result }
    func fetchForecast() async throws -> Data { try result.get() }
}

private let ny = TimeZone(identifier: "America/New_York")!
private func store(_ f: StubFetcher) -> WeatherStore { WeatherStore(fetcher: f, timeZone: ny, logger: Logger(label: "test")) }

private func get(_ app: some ApplicationProtocol, _ uri: String, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, String(buffer: $0.body)) }
    }
}

@Test func notConfiguredIs503AndHealthSaysSo() async throws {
    let app = Application(router: buildRouter(config: TestAuth.config))
    let (status, body) = try await get(app, "/api/weather")
    #expect(status == .serviceUnavailable)
    #expect(body.contains("source_unavailable"))
    let (_, health) = try await get(app, "/healthz")
    #expect(health.contains("not configured"))
}

@Test func emptyStoreIs503() async throws {
    let app = Application(router: buildRouter(config: TestAuth.config, weather: store(StubFetcher(.success(Data())))))
    let (status, body) = try await get(app, "/api/weather")
    #expect(status == .serviceUnavailable)
    #expect(body.contains("source_unavailable"))
}

@Test func servesForecastAndHealthIsOk() async throws {
    let s = store(StubFetcher(.success(try WeatherFixture.data())))
    await s.refresh()
    let app = Application(router: buildRouter(config: TestAuth.config, weather: s))
    let (status, body) = try await get(app, "/api/weather")
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let w = try JSONDecoder().decode(Weather.self, from: Data(body.utf8))
    #expect(w.start == "2026-10-13T00:00:00-04:00")
    #expect(w.t.count == 48)
    let (_, health) = try await get(app, "/healthz")
    let h = try JSONDecoder().decode(Health.self, from: Data(health.utf8))
    #expect(h.feeds.weather.status == .ok)
    #expect(h.feeds.weather.updatedAt != nil)
    #expect(!health.contains("null"))
}

@Test func failureAfterSuccessKeepsServingOldForecast() async throws {
    let fetcher = StubFetcher(.success(try WeatherFixture.data()))
    let s = store(fetcher)
    await s.refresh()
    await fetcher.set(.failure(ForecastFetchError.network(-1009)))
    await s.refresh()
    let app = Application(router: buildRouter(config: TestAuth.config, weather: s))
    let (status, _) = try await get(app, "/api/weather")
    #expect(status == .ok)
    let (_, health) = try await get(app, "/healthz")
    let w = try JSONDecoder().decode(Health.self, from: Data(health.utf8)).feeds.weather
    #expect(w.status == .error)
    #expect(w.detail == "network error -1009")
    #expect(w.updatedAt != nil)
}

@Test func weatherRequiresToken() async throws {
    let app = Application(router: buildRouter(config: TestAuth.config))
    let (status, _) = try await get(app, "/api/weather", headers: [:])
    #expect(status == .unauthorized)
}
