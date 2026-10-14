import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private struct Provider: PhotoProvider {
    var auth: FeedHealth.Authorization = .authorized
    var album: [AssetValues]
    func authorization() async -> FeedHealth.Authorization { auth }
    func albumAssets(title: String) async throws -> [AssetValues] { album }
    func oldestCreationDate() async -> Date? { nil }
    func assets(in ranges: [DateInterval]) async throws -> [AssetValues] { [] }
}

private struct NoPlaces: PlaceLookup {
    func places(for ids: [String]) async -> [String: PlaceInfo] { [:] }
}

private let realShapedID = "B7E1A2C3-0000-4000-8000-000000000001/L0/001"

private func app(auth: FeedHealth.Authorization = .authorized, source: StubImageSource, configured: Bool = true) -> some ApplicationProtocol {
    let feed = PhotosFeed(config: PhotosConfig(album: "Frame"), provider: Provider(auth: auth, album: [asset(realShapedID)]), lookup: NoPlaces(), logger: Logger(label: "test"))
    let images = ImageCache(directory: tempDir(), source: source)
    return Application(router: buildRouter(config: TestAuth.config, photos: configured ? feed : nil, images: configured ? images : nil))
}

private func get(_ app: some ApplicationProtocol, _ uri: String, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, HTTPFields, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, $0.headers, String(buffer: $0.body)) }
    }
}

private let path = "/api/photos/B7E1A2C3-0000-4000-8000-000000000001%2FL0%2F001/image"

@Test func imageRouteServesJpegForEncodedID() async throws {
    let source = StubImageSource()
    let (status, headers, body) = try await get(app(source: source), path)
    #expect(status == .ok)
    #expect(headers[.contentType] == "image/jpeg")
    #expect(headers[.cacheControl] == "max-age=86400")
    #expect(!body.isEmpty)
    #expect(await source.calls.first?.id == realShapedID)
    #expect(await source.calls.first?.maxEdge == 1280)
}

@Test func imageRouteSizeParameter() async throws {
    let half = StubImageSource()
    _ = try await get(app(source: half), path + "?size=half")
    #expect(await half.calls.first?.maxEdge == 640)
    let huge = StubImageSource()
    let (status, _, _) = try await get(app(source: huge), path + "?size=huge")
    #expect(status == .ok)
    #expect(await huge.calls.first?.maxEdge == 1280)
}

@Test func imageRouteUnknownIDIs404() async throws {
    let (status, _, body) = try await get(app(source: StubImageSource()), "/api/photos/NOPE%2FL0%2F001/image")
    #expect(status == .notFound)
    #expect(body.contains("not_found"))
}

@Test func imageRouteRequiresToken() async throws {
    let (status, _, _) = try await get(app(source: StubImageSource()), path, headers: [:])
    #expect(status == .unauthorized)
}

@Test func imageRoute503WhenSourceIsDown() async throws {
    let (denied, _, deniedBody) = try await get(app(auth: .denied, source: StubImageSource()), path)
    #expect(denied == .serviceUnavailable && deniedBody.contains("source_unavailable"))
    let failing = StubImageSource()
    await failing.set(fail: true)
    let (failed, _, failedBody) = try await get(app(source: failing), path)
    #expect(failed == .serviceUnavailable && failedBody.contains("source_unavailable"))
    let (none, _, noneBody) = try await get(app(source: StubImageSource(), configured: false), path)
    #expect(none == .serviceUnavailable && noneBody.contains("not configured"))
}
