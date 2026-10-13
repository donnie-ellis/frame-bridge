import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import FrameBridgeCore

@Test func eventsRequireToken() async throws {
    let app = Application(router: buildRouter(config: TestAuth.config))
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/events", method: .get) { #expect($0.status == .unauthorized) }
    }
}

@Test func streamsRetryThenEvents() async throws {
    let hub = EventHub()
    let app = Application(router: buildRouter(config: TestAuth.config, events: hub))
    Task {
        for _ in 0..<500 {
            if await hub.subscriberCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await hub.weatherChanged()
        await hub.ping()
        await hub.finishAll()
    }
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/events", method: .get, headers: TestAuth.headers) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "text/event-stream")
            #expect(response.headers[.cacheControl] == "no-cache")
            let body = String(buffer: response.body)
            #expect(body.hasPrefix("retry: 5000\n\n"))
            #expect(body.contains("event: weather\ndata: {\"changedAt\":"))
            #expect(body.hasSuffix(": ping\n\n"))
        }
    }
    #expect(await hub.subscriberCount == 0)
}
