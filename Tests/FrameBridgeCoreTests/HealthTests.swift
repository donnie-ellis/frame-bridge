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
            #expect(health.version == contractVersion)
            #expect(health.status == .degraded)
        }
    }
}

@Test func statusIsOkWhenNoFeedFails() {
    let ok = FeedHealth(status: .ok, staleAfterSeconds: 60)
    #expect(Health(feeds: .init(calendar: ok, shopping: ok, lights: ok)).status == .ok)
}
