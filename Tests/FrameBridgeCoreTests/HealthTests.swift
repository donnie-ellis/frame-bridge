import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import FrameBridgeCore

@Test func healthzReportsEveryFeedAndOmitsNulls() async throws {
    let app = Application(router: buildRouter(config: TestAuth.config))
    try await app.test(.router) { client in
        try await client.execute(uri: "/healthz", method: .get, headers: TestAuth.headers) { response in
            #expect(response.status == .ok)
            let body = String(buffer: response.body)
            #expect(!body.contains("null"))
            let health = try JSONDecoder().decode(Health.self, from: Data(body.utf8))
            #expect(health.version == "0.11.0")
            #expect(health.version == contractVersion)
            for key in ["calendar", "shopping", "lights", "weather", "photos"] {
                #expect(body.contains("\"\(key)\""))
            }
            #expect(!body.contains("sonos"))
            #expect(health.feeds.sonos == nil)
            #expect(health.status == .degraded)
        }
    }
}

@Test func statusIsOkWhenNoFeedFails() {
    let ok = FeedHealth(status: .ok, staleAfterSeconds: 60)
    #expect(Health(feeds: .init(calendar: ok, shopping: ok, lights: ok, weather: ok, photos: ok)).status == .ok)
}

@Test func weatherAloneInErrorIsDegraded() {
    let ok = FeedHealth(status: .ok, staleAfterSeconds: 60)
    let bad = FeedHealth(status: .error, staleAfterSeconds: 60, detail: "x")
    #expect(Health(feeds: .init(calendar: ok, shopping: ok, lights: ok, weather: bad, photos: ok)).status == .degraded)
}

@Test func sonosInErrorIsDegradedOnlyWhenPresent() {
    let ok = FeedHealth(status: .ok, staleAfterSeconds: 60)
    let bad = FeedHealth(status: .error, staleAfterSeconds: 60, detail: "x")
    #expect(Health(feeds: .init(calendar: ok, shopping: ok, lights: ok, weather: ok, photos: ok)).status == .ok)
    #expect(Health(feeds: .init(calendar: ok, shopping: ok, lights: ok, weather: ok, photos: ok, sonos: bad)).status == .degraded)
}

@Test func configuredSonosIsReportedInHealthz() async throws {
    let feed = NowPlayingFeed(config: SonosConfig(host: SonosFixture.hostA, room: "Room A"), client: SonosClient(transport: StubSonosTransport()), logger: .init(label: "test"))
    let app = Application(router: buildRouter(config: TestAuth.config, nowPlaying: feed))
    try await app.test(.router) { client in
        try await client.execute(uri: "/healthz", method: .get, headers: TestAuth.headers) { response in
            let body = String(buffer: response.body)
            #expect(!body.contains("null"))
            let sonos = try #require(JSONDecoder().decode(Health.self, from: Data(body.utf8)).feeds.sonos)
            #expect(sonos.status == .error)
            #expect(sonos.detail == "no reading yet")
        }
    }
}
