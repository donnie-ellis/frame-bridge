import CoreGraphics
import Foundation
import Hummingbird
import HummingbirdTesting
import ImageIO
import Logging
import Testing

@testable import FrameBridgeCore

private func polled(_ stub: StubSonosTransport = StubSonosTransport()) async -> NowPlayingFeed {
    let f = NowPlayingFeed(config: SonosConfig(host: SonosFixture.hostA, room: "Room A"), client: SonosClient(transport: stub), externalArt: StubExternalArt(), logger: Logger(label: "test"))
    _ = await f.poll()
    return f
}

private func get(_ feed: NowPlayingFeed?, _ uri: String, headers: HTTPFields = TestAuth.headers) async throws -> (status: HTTPResponse.Status, headers: HTTPFields, body: ByteBuffer) {
    let app = Application(router: buildRouter(config: TestAuth.config, nowPlaying: feed))
    return try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, $0.headers, $0.body) }
    }
}

@Test func nowPlayingServesTheCurrentTrack() async throws {
    let r = try await get(await polled(), "/api/nowplaying")
    #expect(r.status == .ok)
    let text = String(buffer: r.body)
    #expect(!text.contains("null"))
    let value = try JSONDecoder().decode(NowPlaying.self, from: Data(text.utf8))
    #expect(value == NowPlaying(room: "Room A", state: .playing, title: "Example Song", artist: "Example Artist", album: "Example Album", art: true, source: .music))
}

@Test func nowPlayingIs503WhenNotConfigured() async throws {
    let r = try await get(nil, "/api/nowplaying")
    #expect(r.status == .serviceUnavailable)
    #expect(String(buffer: r.body).contains("source_unavailable"))
    #expect(try await get(nil, "/api/nowplaying/art").status == .serviceUnavailable)
}

@Test func nowPlayingIs503WhenTheSpeakerIsDown() async throws {
    let stub = StubSonosTransport()
    await stub.set(unreachable: true)
    let f = await polled(stub)
    #expect(try await get(f, "/api/nowplaying").status == .serviceUnavailable)
    #expect(try await get(f, "/api/nowplaying/art").status == .serviceUnavailable)
}

@Test func artIsAJpegWithNoCache() async throws {
    let r = try await get(await polled(), "/api/nowplaying/art")
    #expect(r.status == .ok)
    #expect(r.headers[.contentType] == "image/jpeg")
    #expect(r.headers[.cacheControl] == "no-cache")
    let source = try #require(CGImageSourceCreateWithData(Data(buffer: r.body) as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 800)
}

@Test func halfSizeFitsIn640AndTheCacheBusterIsIgnored() async throws {
    let r = try await get(await polled(), "/api/nowplaying/art?size=half&v=abc")
    #expect(r.status == .ok)
    let source = try #require(CGImageSourceCreateWithData(Data(buffer: r.body) as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(max(image.width, image.height) <= 640)
}

@Test func artIs404WithoutSpeakerArtAndMakesNoRequest() async throws {
    for position in ["position-radio", "position-tv", "position-empty"] {
        let stub = StubSonosTransport(position: position)
        let r = try await get(await polled(stub), "/api/nowplaying/art")
        #expect(r.status == .notFound)
        #expect(String(buffer: r.body).contains("not_found"))
        #expect(await stub.gets.isEmpty)
    }
}

@Test func nowPlayingRoutesNeedTheToken() async throws {
    let f = await polled()
    #expect(try await get(f, "/api/nowplaying", headers: [:]).status == .unauthorized)
    #expect(try await get(f, "/api/nowplaying/art", headers: [:]).status == .unauthorized)
}
