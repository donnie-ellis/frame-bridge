import Foundation
import Logging
import Testing

@testable import FrameBridgeCore

private let hue = HueConfig(bridge: "bridge.invalid", sceneIcons: HueFixture.icons)
private let fixedNow = Date(timeIntervalSince1970: 1_791_839_051)

private func makeFeed(_ transport: FakeHueTransport, events: EventHub? = nil, resync: Duration = .milliseconds(40)) -> LightsFeed {
    LightsFeed(config: hue, client: HueClient(transport: transport), logger: Logger(label: "test"), now: { fixedNow }, events: events, resyncInterval: resync)
}

/// Everything the hub sent so far, as SSE text.
private func drain(_ hub: EventHub, _ stream: AsyncStream<String>) async -> [String] {
    await hub.finishAll()
    var out: [String] = []
    for await message in stream { out.append(message) }
    return out
}

private func eventNames(_ messages: [String]) -> [String] {
    messages.compactMap { $0.split(separator: "\n").first.map(String.init) }.map { $0.replacingOccurrences(of: "event: ", with: "") }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func payloads(_ fixture: String) throws -> [String] {
    var parser = HueEventStreamParser()
    return parser.feed(Data(try HueFixture.text(fixture).utf8))
}

actor FakeHueEventStream: HueEventStreamTransport {
    enum Step { case fail(HueClientError), open }
    private var steps: [Step]
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private(set) var opens = 0

    init(_ steps: [Step]) { self.steps = steps }

    func eventStream() async throws -> AsyncThrowingStream<Data, any Error> {
        opens += 1
        if case .fail(let error)? = steps.first {
            steps.removeFirst()
            throw error
        }
        if !steps.isEmpty { steps.removeFirst() }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func send(_ text: String) { continuation?.yield(Data(text.utf8)) }
}

actor SleepLog {
    private(set) var delays: [Duration] = []
    private(set) var notes: [String] = []
    func record(_ d: Duration) { delays.append(d) }
    func note(_ text: String) { notes.append(text) }
}

@Test func backoffDoublesToSixtySeconds() {
    #expect((1...8).map { HueBackoff.delay($0) } == [1, 2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
}

@Test func stateIsServedFromTheCacheWhileConnected() async throws {
    let fake = FakeHueTransport()
    let feed = makeFeed(fake)
    try await feed.streamOpened()
    #expect(await fake.recorded().count == 6)
    _ = try await feed.state()
    let again = try await feed.state()
    #expect(again.devices.count == 4)
    #expect(await fake.recorded().count == 6)
}

@Test func streamEventsUpdateTheCacheAndReachSubscribers() async throws {
    let fake = FakeHueTransport()
    let hub = EventHub()
    let feed = makeFeed(fake, events: hub)
    try await feed.streamOpened()
    let (_, stream) = await hub.subscribe(bufferSize: 64)
    for message in try payloads("light-update") { await feed.apply(payload: message) }

    let state = try await feed.state()
    #expect(state.devices.first { $0.id == HueFixture.light(1) }?.on == false)
    #expect(state.devices.first { $0.id == HueFixture.light(1) }?.level == 80)
    let sent = await drain(hub, stream)
    #expect(eventNames(sent) == ["light", "light", "room"])
    #expect(sent.allSatisfy { !$0.contains("null") })
    #expect(await fake.recorded().count == 6)
}

@Test func warmUpSendsNothing() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    try await makeFeed(FakeHueTransport(), events: hub).streamOpened()
    #expect(await drain(hub, stream).isEmpty)
}

@Test func aStructuralBurstIsOneReadAndOneLightsNoticeAfterTheEvents() async throws {
    let fake = FakeHueTransport()
    await fake.hideScene(HueFixture.scene(4))
    let hub = EventHub()
    let feed = makeFeed(fake, events: hub)
    try await feed.streamOpened()
    #expect(try await feed.state().scenes.count == 4)
    await fake.hideScene(nil)
    let (_, stream) = await hub.subscribe(bufferSize: 64)

    for message in try payloads("structural") { await feed.apply(payload: message) }
    #expect(await waitUntil { await fake.recorded().count >= 12 })
    try await Task.sleep(for: .milliseconds(150))
    #expect(await fake.recorded().count == 12)

    let names = eventNames(await drain(hub, stream))
    #expect(names == ["scene", "lights"])
    #expect(try await feed.state().scenes.count == 5)
}

@Test func aResyncWithTheSameIDsSendsNoLightsNotice() async throws {
    let fake = FakeHueTransport()
    let hub = EventHub()
    let feed = makeFeed(fake, events: hub)
    try await feed.streamOpened()
    let (_, stream) = await hub.subscribe()
    for message in try payloads("structural") { await feed.apply(payload: message) }
    #expect(await waitUntil { await fake.recorded().count >= 12 })
    try await Task.sleep(for: .milliseconds(150))
    #expect(await fake.recorded().count == 12)
    #expect(await drain(hub, stream).isEmpty)
}

@Test func aPutSendsNoEventAndLeavesTheCache() async throws {
    let fake = FakeHueTransport()
    let hub = EventHub()
    let feed = makeFeed(fake, events: hub)
    try await feed.streamOpened()
    let (_, stream) = await hub.subscribe()
    let light = try await feed.set(id: HueFixture.light(2), patch: LightPatch(on: true, level: 60))
    #expect(light.on && light.level == 60)
    let cached = try await feed.state().devices.first { $0.id == HueFixture.light(2) }
    #expect(cached?.on == false && cached?.level == 50)
    #expect(await drain(hub, stream).isEmpty)
}

@Test func healthFollowsTheStream() async throws {
    let feed = makeFeed(FakeHueTransport())
    let before = await feed.health()
    #expect(before.status == .error && before.detail == "Hue event stream not connected")
    try await feed.streamOpened()
    let ok = await feed.health()
    #expect(ok.status == .ok && ok.updatedAt == WireDate.string(from: fixedNow) && ok.staleAfterSeconds == 120)
    await feed.streamClosed(reason: "Hue Bridge not reachable")
    let closed = await feed.health()
    #expect(closed.status == .error && closed.detail == "Hue Bridge not reachable" && closed.updatedAt != nil)
}

@Test func theServiceReconnectsAfterAFailureAndFeedsTheCache() async throws {
    let fake = FakeHueTransport()
    let stream = FakeHueEventStream([.fail(.unreachable), .open])
    let feed = makeFeed(fake)
    let log = SleepLog()
    var service = LightsService(feed: feed, transport: stream, logger: Logger(label: "test"))
    service.sleep = { await log.record($0) }
    let task = Task { await service.connectLoop() }

    #expect(await waitUntil { await feed.health().status == .ok })
    #expect(await log.delays == [.seconds(1)])
    #expect(await stream.opens == 2)

    await stream.send(try HueFixture.text("light-update"))
    #expect(await waitUntil { (try? await feed.state().devices.first { $0.id == HueFixture.light(1) }?.on) == false })
    task.cancel()
    await task.value
}

@Test func aStreamFailureLogsItsCodeAndShowsItInHealth() async throws {
    let (logger, captured) = CapturingLogHandler.logger()
    let stream = FakeHueEventStream([.fail(.network(.networkConnectionLost)), .open])
    let feed = makeFeed(FakeHueTransport())
    let seen = SleepLog()
    var service = LightsService(feed: feed, transport: stream, logger: logger)
    service.sleep = { delay in
        await seen.record(delay)
        let health = await feed.health()
        if health.detail?.hasPrefix("Hue event stream:") == true { await seen.note(health.detail ?? "") }
    }
    let task = Task { await service.connectLoop() }
    #expect(await waitUntil { await feed.health().status == .ok })
    task.cancel()
    await task.value

    #expect(await seen.notes == ["Hue event stream: connection lost (-1005)"])
    let warning = captured.entries.first { $0.message == "hue event stream failed" }
    #expect(warning?.metadata == ["reason": "networkConnectionLost", "code": "-1005"])
}

@Test func aPinMismatchOnTheStreamSaysSoInHealth() async throws {
    let stream = FakeHueEventStream([.fail(.pinMismatch), .open])
    let feed = makeFeed(FakeHueTransport())
    let seen = SleepLog()
    var service = LightsService(feed: feed, transport: stream, logger: Logger(label: "test"))
    service.sleep = { _ in
        let detail = await feed.health().detail ?? ""
        if detail != "Hue event stream closed" { await seen.note(detail) }
    }
    let task = Task { await service.connectLoop() }
    #expect(await waitUntil { await feed.health().status == .ok })
    task.cancel()
    await task.value
    #expect(await seen.notes == ["Hue Bridge certificate doesn't match the pin: run hue-pair"])
}

@Test func aResyncFailureLogsItsCode() async throws {
    let (logger, captured) = CapturingLogHandler.logger()
    let fake = FakeHueTransport()
    let feed = LightsFeed(config: hue, client: HueClient(transport: fake), logger: logger, now: { fixedNow }, resyncInterval: .milliseconds(40))
    try await feed.streamOpened()
    await fake.setFailure(HueClientError.network(.timedOut))
    for message in try payloads("structural") { await feed.apply(payload: message) }
    #expect(await waitUntil { captured.entries.contains { $0.message == "hue resync failed" } })

    let warning = captured.entries.first { $0.message == "hue resync failed" }
    #expect(warning?.metadata == ["reason": "timedOut", "code": "-1001"])
    let all = captured.entries.flatMap { $0.metadata.values.map { "\($0)" } } + [await feed.health().detail ?? ""]
    #expect(all.allSatisfy { !$0.contains("bridge.invalid") })
}
