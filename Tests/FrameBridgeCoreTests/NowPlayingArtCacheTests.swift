import Foundation
import ImageIO
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private func makeFeed(_ stub: StubSonosTransport, external: StubExternalArt = StubExternalArt(), events: EventHub? = nil) -> NowPlayingFeed {
    NowPlayingFeed(config: SonosConfig(host: SonosFixture.hostA, room: "Room A"), client: SonosClient(transport: stub), externalArt: external, events: events, logger: Logger(label: "test"))
}

private func artStatus(_ feed: NowPlayingFeed, _ uri: String = "/api/nowplaying/art") async throws -> HTTPResponse.Status {
    let app = Application(router: buildRouter(config: TestAuth.config, nowPlaying: feed))
    return try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: TestAuth.headers) { $0.status }
    }
}

@Test func artIsFetchedOncePerTrack() async throws {
    let stub = StubSonosTransport()
    let f = makeFeed(stub)
    _ = await f.poll()
    for _ in 0..<5 { _ = await f.poll() }
    _ = try await f.artJPEG(size: .full)
    _ = try await f.artJPEG(size: .half)
    _ = try await f.artJPEG(size: .full)
    #expect(await stub.gets.count == 1)
}

@Test func requestsNeverContactTheSpeaker() async throws {
    let stub = StubSonosTransport()
    let f = makeFeed(stub)
    _ = await f.poll()
    let before = await stub.gets.count
    for i in 0..<10 {
        #expect(try await artStatus(f, i.isMultiple(of: 2) ? "/api/nowplaying/art" : "/api/nowplaying/art?size=half") == .ok)
    }
    #expect(await stub.gets.count == before)
    await stub.set(unreachable: true)
    #expect(try await artStatus(f) == .ok)
    #expect(await stub.gets.count == before)
}

@Test func trackChangeFetchesAgain() async throws {
    let stub = StubSonosTransport()
    let f = makeFeed(stub)
    _ = await f.poll()
    await stub.set(position: "position-music-other-art")
    _ = await f.poll()
    let gets = await stub.gets
    #expect(gets.count == 2)
    #expect(Set(gets).count == 2)
    #expect(try await artStatus(f) == .ok)
}

@Test func outageClearsTheCache() async throws {
    let stub = StubSonosTransport()
    let f = makeFeed(stub)
    _ = await f.poll()
    await stub.set(unreachable: true)
    _ = await f.poll()
    await #expect(throws: APIError.self) { try await f.artJPEG(size: .full) }
    await stub.set(unreachable: false)
    _ = await f.poll()
    #expect(await stub.gets.count == 2)
    #expect(try await artStatus(f) == .ok)
}

@Test func failedArtFetchMeansArtFalseAnd404() async throws {
    let stub = StubSonosTransport()
    await stub.set(artStatus: 404)
    let f = makeFeed(stub)
    _ = await f.poll()
    #expect(try await f.current().art == false)
    #expect(try await artStatus(f) == .notFound)
    _ = await f.poll()
    #expect(await stub.gets.count == 1)
    await stub.set(position: "position-music-other-art", artStatus: 200)
    _ = await f.poll()
    #expect(await stub.gets.count == 2)
    #expect(try await f.current().art == true)
    #expect(try await artStatus(f) == .ok)
}

@Test func noArtTrackClearsCache() async throws {
    let stub = StubSonosTransport()
    let f = makeFeed(stub)
    _ = await f.poll()
    await stub.set(position: "position-radio")
    _ = await f.poll()
    #expect(try await artStatus(f) == .notFound)
    #expect(try await f.current().art != true)
}

@Test func artFlagMatchesCache() async throws {
    let hub = EventHub()
    let sub = await hub.subscribe()
    let f = makeFeed(StubSonosTransport(), events: hub)
    _ = await f.poll()
    var it = sub.stream.makeAsyncIterator()
    let message = try #require(await it.next())
    #expect(message.contains("nowplaying"))
    #expect(message.contains("\"art\":true"))
    #expect(try await artStatus(f) == .ok)
    await hub.remove(sub.id)
}

@Test func radioArtIsFetchedOnceFromTheAllowedHostNeverTheSpeaker() async throws {
    let stub = StubSonosTransport(position: "position-radio-stream")
    let external = StubExternalArt()
    let f = makeFeed(stub, external: external)
    for _ in 0..<6 { _ = await f.poll() }
    #expect(await external.urls.count == 1)
    #expect(await stub.gets.isEmpty)
    #expect(try await f.current().art == true)
    let half = try await f.artJPEG(size: .half)
    let image = try #require(CGImageSourceCreateWithData(half as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(max(image.width, image.height) <= 640)
    #expect(try await artStatus(f) == .ok)
}

@Test func failedExternalFetchMeansArtFalseAnd404WithoutRetry() async throws {
    let stub = StubSonosTransport(position: "position-radio-stream")
    let external = StubExternalArt()
    await external.set(fail: true)
    let f = makeFeed(stub, external: external)
    _ = await f.poll()
    _ = await f.poll()
    #expect(try await f.current().art == false)
    #expect(try await artStatus(f) == .notFound)
    #expect(await external.urls.count == 1)
}

@Test func changedExternalArtFetchesAgain() async throws {
    let stub = StubSonosTransport(position: "position-radio-stream")
    let external = StubExternalArt()
    let f = makeFeed(stub, external: external)
    _ = await f.poll()
    await stub.set(position: "position-radio-stream-next")
    _ = await f.poll()
    #expect(await external.urls.count == 2)
}

@Test func nonAllowedExternalArtFetchesNothing() async throws {
    let stub = StubSonosTransport(position: "position-radio")
    let external = StubExternalArt()
    let f = makeFeed(stub, external: external)
    _ = await f.poll()
    #expect(await external.urls.isEmpty)
    #expect(await stub.gets.isEmpty)
}
