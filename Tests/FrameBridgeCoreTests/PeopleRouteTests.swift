import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import FrameBridgeCore

private func config(_ people: [Person]?) -> Config {
    var c = TestAuth.config
    c = Config(frames: c.frames, dashboardDir: c.dashboardDir, people: people)
    return c
}

@Test func peopleRouteServesConfigOrder() async throws {
    let people = [Person(id: "z", name: "Z", color: "#112233", night: "#aabbcc"), Person(id: "a", name: "A", color: "#445566")]
    let app = Application(router: buildRouter(config: config(people)))
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/people", method: .get, headers: TestAuth.headers) { response in
            #expect(response.status == .ok)
            let body = String(buffer: response.body)
            #expect(!body.contains("null"))
            let raw = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]])
            #expect(raw.map { $0["id"] as? String } == ["z", "a"])
            #expect(raw[0]["night"] as? String == "#aabbcc")
            #expect(raw[1]["night"] == nil)
        }
    }
}

@Test func peopleRouteIs503WhenMissingOrEmpty() async throws {
    for people in [nil, [Person]()] {
        let app = Application(router: buildRouter(config: config(people)))
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/people", method: .get, headers: TestAuth.headers) { response in
                #expect(response.status == .serviceUnavailable)
                let body = try #require(JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: String])
                #expect(body == ["error": "source_unavailable", "detail": "not configured"])
            }
        }
    }
}

@Test func peopleRouteNeedsToken() async throws {
    let app = Application(router: buildRouter(config: config([Person(id: "a", name: "A", color: "#112233")])))
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/people", method: .get) { response in
            #expect(response.status == .unauthorized)
            #expect(String(buffer: response.body) == #"{"error":"unauthorized"}"#)
        }
    }
}
