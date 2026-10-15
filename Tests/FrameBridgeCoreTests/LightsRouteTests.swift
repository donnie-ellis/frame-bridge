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
    let expected = try LightsMapping.hueBody(for: LightPatch(on: true, level: 60), light: HueFixture.resources().lights[1])
    #expect(puts.first?.body == expected)
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

    let live = feed(FakeHueTransport())
    let a = app(live)
    let before = try await lightsHealth(a)
    #expect(before.status == .error && before.detail == "Hue event stream not connected")
    try await live.streamOpened()
    let ok = try await lightsHealth(a)
    #expect(ok.status == .ok && ok.updatedAt != nil && ok.staleAfterSeconds == 120)

    await live.streamClosed(reason: "Hue Bridge not reachable")
    let closed = try await lightsHealth(a)
    #expect(closed.status == .error && closed.detail == "Hue Bridge not reachable")
}

private func puts(_ fake: FakeHueTransport) async -> [FakeHueTransport.Request] {
    await fake.recorded().filter { $0.method != "GET" }
}

@Test func setRoomOffKeepsLevelAndSendsOneGroupedPut() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .put, "/api/rooms/\(HueFixture.roomA)", body: #"{"on":false}"#)
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let room = try JSONDecoder().decode(Room.self, from: Data(body.utf8))
    #expect(room == Room(id: HueFixture.roomA, name: room.name, kind: .room, on: false, level: 80, lights: [HueFixture.light(1), HueFixture.light(2)]))
    let sent = await puts(fake)
    #expect(sent.count == 1)
    #expect(sent.first?.path == "resource/grouped_light/\(HueFixture.grouped(1))")
    #expect(sent.first?.body == LightsMapping.hueBody(for: RoomPatch(on: false), dimmable: true))
}

@Test func setRoomLevelOnAnOffRoomTurnsItOn() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .put, "/api/rooms/\(HueFixture.roomB)", body: #"{"level":60}"#)
    #expect(status == .ok)
    let room = try JSONDecoder().decode(Room.self, from: Data(body.utf8))
    #expect(room.on && room.level == 60)
    let sent = await puts(fake)
    #expect(sent.count == 1)
    #expect(sent.first?.body == LightsMapping.hueBody(for: RoomPatch(level: 60), dimmable: true))
}

@Test func setRoomWorksForAZone() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .put, "/api/rooms/\(HueFixture.zone)", body: #"{"on":true,"level":30}"#)
    #expect(status == .ok)
    let room = try JSONDecoder().decode(Room.self, from: Data(body.utf8))
    #expect(room.kind == .zone && room.on && room.level == 30)
    #expect(await puts(fake).map(\.path) == ["resource/grouped_light/\(HueFixture.grouped(3))"])
}

@Test func setRoomUnknownOrWithoutGroupedLightIs404() async throws {
    let fake = FakeHueTransport()
    let a = app(feed(fake))
    for id in ["nope", HueFixture.roomC] {
        let (status, body) = try await call(a, .put, "/api/rooms/\(id)", body: #"{"on":true}"#)
        #expect(status == .notFound)
        #expect(body.contains("not_found"))
    }
    #expect(await puts(fake).isEmpty)
}

@Test func setRoomBadBodyIs400AndNothingIsSent() async throws {
    let fake = FakeHueTransport()
    let a = app(feed(fake))
    for bad in ["{}", #"{"level":0}"#, #"{"level":1.5}"#, #"{"on":"yes"}"#, #"{"foo":1}"#, "not json"] {
        let (status, body) = try await call(a, .put, "/api/rooms/\(HueFixture.roomA)", body: bad)
        #expect(status == .badRequest)
        #expect(body.contains("bad_request"))
    }
    #expect(await fake.recorded().isEmpty)
}

@Test func recallSceneSendsOneSceneAndReturnsItActive() async throws {
    let fake = FakeHueTransport()
    let id = HueFixture.scene(6)
    let (status, body) = try await call(app(feed(fake)), .post, "/api/scenes/\(id)/recall")
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let scene = try JSONDecoder().decode(Scene.self, from: Data(body.utf8))
    #expect(scene == Scene(id: id, room: HueFixture.zone, name: "Dinner", active: true, icon: "utensils"))
    let sent = await puts(fake)
    #expect(sent.count == 1)
    #expect(sent.first?.method == "PUT" && sent.first?.path == "resource/scene/\(id)")
    #expect(sent.first?.body == LightsMapping.recallBody)
}

@Test func recallSceneWithoutIconOmitsTheKey() async throws {
    let (status, body) = try await call(app(feed(FakeHueTransport())), .post, "/api/scenes/\(HueFixture.scene(3))/recall")
    #expect(status == .ok)
    #expect(!body.contains("icon"))
    let scene = try JSONDecoder().decode(Scene.self, from: Data(body.utf8))
    #expect(scene.active && scene.room == HueFixture.roomB)
}

@Test func recallUnknownSceneOrOneInADroppedRoomIs404() async throws {
    let fake = FakeHueTransport()
    let a = app(feed(fake))
    for id in ["nope", HueFixture.scene(5)] {
        let (status, body) = try await call(a, .post, "/api/scenes/\(id)/recall")
        #expect(status == .notFound)
        #expect(body.contains("not_found"))
    }
    #expect(await puts(fake).isEmpty)
}

private let roomCalls: [(HTTPRequest.Method, String, String?)] = [
    (.put, "/api/rooms/\(HueFixture.roomA)", #"{"on":false}"#),
    (.post, "/api/scenes/\(HueFixture.scene(6))/recall", nil),
]

@Test func roomAndSceneRoutesAre503WhenNotConfiguredOrNotPaired() async throws {
    for a in [app(nil), app(feed(nil))] {
        for (method, uri, body) in roomCalls {
            let (status, text) = try await call(a, method, uri, body: body)
            #expect(status == .serviceUnavailable)
            #expect(text.contains("source_unavailable"))
        }
    }
}

@Test func roomAndSceneRoutesAre503WhenTheBridgeFails() async throws {
    let unreachable = FakeHueTransport()
    await unreachable.setFailure(HueClientError.unreachable)
    let rejected = FakeHueTransport()
    await rejected.setStatus(401)
    for fake in [unreachable, rejected] {
        let a = app(feed(fake))
        for (method, uri, body) in roomCalls {
            let (status, _) = try await call(a, method, uri, body: body)
            #expect(status == .serviceUnavailable)
        }
    }
}

@Test func roomAndSceneRoutesNeedTheCookie() async throws {
    let fake = FakeHueTransport()
    let a = app(feed(fake))
    for (method, uri, body) in roomCalls {
        let (status, _) = try await call(a, method, uri, body: body, headers: [:])
        #expect(status == .unauthorized)
    }
    #expect(await fake.recorded().isEmpty)
}

@Test func putLightTempIsOneHuePutAndTheResponseHasTemp() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .put, "/api/lights/\(HueFixture.light(2))", body: #"{"temp":2700}"#)
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let light = try JSONDecoder().decode(Light.self, from: Data(body.utf8))
    #expect(light.on && light.temp == 2703 && light.tempRange != nil)
    let sent = await puts(fake)
    #expect(sent.count == 1)
}

@Test func putLightColorLeavesWhiteMode() async throws {
    let fake = FakeHueTransport()
    let (status, body) = try await call(app(feed(fake)), .put, "/api/lights/\(HueFixture.light(1))", body: ##"{"color":"#ff8a3d"}"##)
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let light = try JSONDecoder().decode(Light.self, from: Data(body.utf8))
    #expect(light.temp == nil && light.color != nil)
    #expect(!body.contains("\"temp\""))
    #expect(await puts(fake).count == 1)
}

@Test func putLightBadTempOrColorIs400WithoutAHuePut() async throws {
    let fake = FakeHueTransport()
    let a = app(feed(fake))
    let cases = [
        (HueFixture.light(1), ##"{"temp":2700,"color":"#ff8a3d"}"##),
        (HueFixture.light(1), ##"{"color":"#000000"}"##),
        (HueFixture.light(4), #"{"temp":2700}"#),
        (HueFixture.light(4), ##"{"color":"#ff8a3d"}"##),
    ]
    for (id, json) in cases {
        let (status, body) = try await call(a, .put, "/api/lights/\(id)", body: json)
        #expect(status == .badRequest, "\(json)")
        #expect(body.contains("bad_request"))
    }
    #expect(await puts(fake).isEmpty)
}

@Test func putRoomWithTempOrColorIs400WithoutAHuePut() async throws {
    let fake = FakeHueTransport()
    let a = app(feed(fake))
    for json in [#"{"temp":2700}"#, ##"{"color":"#ff8a3d"}"##] {
        let (status, _) = try await call(a, .put, "/api/rooms/\(HueFixture.roomA)", body: json)
        #expect(status == .badRequest)
    }
    #expect(await puts(fake).isEmpty)
}
