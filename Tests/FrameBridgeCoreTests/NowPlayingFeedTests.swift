import Foundation
import Logging
import Testing

@testable import FrameBridgeCore

private let config = SonosConfig(host: SonosFixture.hostA, room: "Room A")

private func feed(_ stub: StubSonosTransport, events: EventHub? = nil) -> NowPlayingFeed {
    NowPlayingFeed(config: config, client: SonosClient(transport: stub), externalArt: StubExternalArt(), events: events, logger: Logger(label: "test"))
}

@Test func firstPollSetsValueAndSendsOneEvent() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    let f = feed(StubSonosTransport(), events: hub)
    let next = await f.poll()
    #expect(next == .seconds(5))
    var iterator = stream.makeAsyncIterator()
    let message = try #require(await iterator.next())
    #expect(message.hasPrefix("event: nowplaying\ndata: {"))
    #expect(message.contains(#""title":"Example Song""#))
    #expect(try await f.current().state == .playing)
}

@Test func unchangedPollSendsNothing() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    let f = feed(StubSonosTransport(), events: hub)
    _ = await f.poll()
    await f.artSettled()
    _ = await f.poll()
    await f.artSettled()
    await hub.finishAll()
    let messages = await Array(stream)
    #expect(messages.count == 2)
}

@Test func transitioningKeepsTheValueAndSendsNothing() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    let stub = StubSonosTransport()
    let f = feed(stub, events: hub)
    _ = await f.poll()
    await f.artSettled()
    await stub.set(transport: "transport-transitioning", position: "position-empty")
    _ = await f.poll()
    await f.artSettled()
    await hub.finishAll()
    #expect(await Array(stream).count == 2)
    #expect(try await f.current().title == "Example Song")
}

@Test func pausedAndStoppedPollEveryFifteenSeconds() async {
    let stub = StubSonosTransport(transport: "transport-paused")
    let f = feed(stub)
    #expect(await f.poll() == .seconds(15))
    await stub.set(transport: "transport-stopped")
    #expect(await f.poll() == .seconds(15))
}

@Test func unreachableDropsTheValueWithoutAnEventAndRecoverySendsOne() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    let stub = StubSonosTransport()
    let f = feed(stub, events: hub)
    _ = await f.poll()
    await f.artSettled()
    await stub.set(unreachable: true)
    #expect(await f.poll() == .seconds(15))
    await #expect(throws: APIError.self) { try await f.current() }
    let bad = await f.health()
    #expect(bad.status == .error)
    #expect(bad.detail == "speaker not reachable")
    await stub.set(position: "position-music-next", unreachable: false)
    _ = await f.poll()
    await f.artSettled()
    #expect(await f.health().status == .ok)
    await hub.finishAll()
    let messages = await Array(stream)
    #expect(messages.count == 4)
    #expect(messages[2].contains(#""title":"Example Song 2""#))
    #expect(messages[3].contains(#""title":"Example Song 2""#))
}

@Test func trackChangeSendsASecondEvent() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    let stub = StubSonosTransport()
    let f = feed(stub, events: hub)
    _ = await f.poll()
    await f.artSettled()
    await stub.set(position: "position-music-next")
    _ = await f.poll()
    await f.artSettled()
    await hub.finishAll()
    let messages = await Array(stream)
    #expect(messages.count == 4)
    #expect(messages.allSatisfy { $0.hasPrefix("event: nowplaying\ndata: {") })
    #expect(messages[2].contains(#""title":"Example Song 2""#))
    #expect(messages[2].contains(#""state":"playing""#))
    #expect(try await f.current().title == "Example Song 2")
}

@Test func pauseSendsAnEventWithStatePaused() async throws {
    let hub = EventHub()
    let (_, stream) = await hub.subscribe()
    let stub = StubSonosTransport()
    let f = feed(stub, events: hub)
    _ = await f.poll()
    await f.artSettled()
    await stub.set(transport: "transport-paused")
    #expect(await f.poll() == .seconds(15))
    _ = await f.poll()
    await f.artSettled()
    await hub.finishAll()
    let messages = await Array(stream)
    #expect(messages.count == 3)
    #expect(messages[2].contains(#""state":"paused""#))
    #expect(messages[2].contains(#""title":"Example Song""#))
    #expect(try await f.current().state == .paused)
}

@Test func healthIsErrorBeforeTheFirstReading() async {
    let h = await feed(StubSonosTransport()).health()
    #expect(h.status == .error)
    #expect(h.detail == "no reading yet")
    #expect(h.updatedAt == nil)
}

@Test func unknownRoomIsReported() async {
    let f = NowPlayingFeed(config: SonosConfig(host: SonosFixture.hostA, room: "Room Z"), client: SonosClient(transport: StubSonosTransport()), externalArt: StubExternalArt(), logger: Logger(label: "test"))
    _ = await f.poll()
    let h = await f.health()
    #expect(h.detail == "room not found in Sonos topology")
    #expect(!(h.detail ?? "").contains("Room Z"))
}

@Test func onlyReadOnlyActionsAndArtGetsAreSent() async throws {
    let stub = StubSonosTransport(topology: "topology-grouped")
    let f = feed(stub)
    _ = await f.poll()
    await f.artSettled()
    _ = try await f.artJPEG(size: .full)
    let actions = Set(await stub.actions)
    #expect(actions.isSubset(of: ["GetZoneGroupState", "GetTransportInfo", "GetPositionInfo"]))
    #expect(actions.count == 3)
    #expect(await stub.gets.allSatisfy { $0.hasPrefix("/getaa") })
}

@Test func clientRefusesNonGetaaPaths() async {
    let client = SonosClient(transport: StubSonosTransport())
    await #expect(throws: SonosError.badResponse) { try await client.art(host: SonosFixture.hostA, path: "http://evil.invalid/getaa") }
    await #expect(throws: SonosError.badResponse) { try await client.art(host: SonosFixture.hostA, path: "/other") }
}
