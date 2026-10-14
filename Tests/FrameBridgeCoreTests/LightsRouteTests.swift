import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private let hue = HueConfig(bridge: "bridge.invalid", sceneIcons: HueFixture.icons)

private func feed(_ transport: FakeHueTransport?) -> LightsFeed {
    LightsFeed(config: hue, client: transport.map { HueClient(transport: $0) }, logger: Logger(label: "test"))
}

private func app(_ lights: LightsFeed?) -> some ApplicationProtocol {
    Application(router: buildRouter(config: TestAuth.config, lights: lights))
}

private func call(_ app: some ApplicationProtocol, _ method: HTTPRequest.Method, _ uri: String, body: String? = nil, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: uri, method: method, headers: headers, body: body.map { ByteBuffer(string: $0) }) { ($0.status, String(buffer: $0.body)) }
    }
}

private let oneID = HueFixture.light(1)

@Test func getLightsServesStateWithoutNull() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .get, "/api/lights")
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let state = try JSONDecoder().decode(LightsState.self, from: Data(body.utf8))
    #expect(state.rooms.count == 3 && state.devices.count == 4 && state.scenes.count == 5)
    let paths = await fake.recorded().map(\.path).sorted()
    #expect(paths == ["resource/device", "resource/grouped_light", "resource/light", "resource/room", "resource/scene", "resource/zone"])
}

@Test func putLightReturnsTheStateReReadFromTheBridge() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .put, "/api/lights/\(HueFixture.light(2))", body: #"{"on":true,"level":60}"#)
    #expect(status == .ok)
    let light = try JSONDecoder().decode(Light.self, from: Data(body.utf8))
    #expect(light.on && light.level == 60 && light.room == HueFixture.roomA)
    let puts = await fake.recorded().filter { $0.method == "PUT" }
    #expect(puts.count == 1)
    #expect(puts.first?.body == LightsMapping.hueBody(for: LightPatch(on: true, level: 60), dimmable: true))
    #expect(!body.contains("null"))
}

@Test func putUnknownOrRoomlessLightIs404() async throws {
    let fake = FakeHueTransport()
    let a = app(feed(fake))
    for id in ["nope", HueFixture.light(5), HueFixture.light(6)] {
        let (status, body) = try await call(a, .put, "/api/lights/\(id)", body: #"{"on":true}"#)
        #expect(status == .notFound)
        #expect(body.contains("not_found"))
    }
    #expect(await fake.recorded().filter { $0.method == "PUT" }.isEmpty)
}

@Test func putBadBodyIs400AndNothingIsSent() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .put, "/api/lights/\(oneID)", body: #"{"level":0}"#)
    #expect(status == .badRequest)
    #expect(body.contains("bad_request"))
    #expect(await fake.recorded().isEmpty)
}

@Test func unreachableBridgeIs503OnBothRoutes() async throws {
    let fake = FakeHueTransport()
    await fake.setFailure(HueClientError.unreachable)
    let a = app(feed(fake))
    let (getStatus, getBody) = try await call(a, .get, "/api/lights")
    #expect(getStatus == .serviceUnavailable)
    #expect(getBody.contains("source_unavailable"))
    let (putStatus, _) = try await call(a, .put, "/api/lights/\(oneID)", body: #"{"on":true}"#)
    #expect(putStatus == .serviceUnavailable)
}

@Test func rejectedKeyIs503() async throws {
    let fake = FakeHueTransport()
    await fake.setStatus(403)
    let (status, body) = try await call(app(feed(fake)), .get, "/api/lights")
    #expect(status == .serviceUnavailable)
    #expect(body.contains("hue-pair"))
}

@Test func noFeedIsNotConfigured() async throws {
    let a = app(nil)
    for (method, uri, body) in [(HTTPRequest.Method.get, "/api/lights", nil), (.put, "/api/lights/x", #"{"on":true}"#)] as [(HTTPRequest.Method, String, String?)] {
        let (status, text) = try await call(a, method, uri, body: body)
        #expect(status == .serviceUnavailable)
        #expect(text.contains("not configured"))
    }
}

@Test func nilClientIsNotPaired() async throws {
    let a = app(feed(nil))
    let (status, text) = try await call(a, .get, "/api/lights")
    #expect(status == .serviceUnavailable)
    #expect(text.contains("not paired"))
    let (putStatus, _) = try await call(a, .put, "/api/lights/x", body: #"{"on":true}"#)
    #expect(putStatus == .serviceUnavailable)
}

@Test func lightsRoutesNeedTheCookie() async throws {
    let a = app(feed(FakeHueTransport()))
    let (g, _) = try await call(a, .get, "/api/lights", headers: [:])
    let (p, _) = try await call(a, .put, "/api/lights/\(oneID)", body: #"{"on":true}"#, headers: [:])
    #expect(g == .unauthorized && p == .unauthorized)
}

@Test func healthzReportsLights() async throws {
    func lightsHealth(_ a: some ApplicationProtocol) async throws -> FeedHealth {
        let (_, body) = try await call(a, .get, "/healthz")
        return try JSONDecoder().decode(Health.self, from: Data(body.utf8)).feeds.lights
    }
    let none = try await lightsHealth(app(nil))
    #expect(none.status == .error && none.detail == "not configured")

    let fake = FakeHueTransport()
    let live = app(feed(fake))
    let before = try await lightsHealth(live)
    #expect(before.status == .error && before.detail == "not read yet")
    _ = try await call(live, .get, "/api/lights")
    let ok = try await lightsHealth(live)
    #expect(ok.status == .ok && ok.updatedAt != nil && ok.staleAfterSeconds == 120)

    await fake.setFailure(HueClientError.unreachable)
    _ = try await call(live, .get, "/api/lights")
    let failed = try await lightsHealth(live)
    #expect(failed.status == .error && failed.detail != nil)
}
