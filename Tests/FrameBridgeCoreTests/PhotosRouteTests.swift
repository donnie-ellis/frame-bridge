import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private actor StubProvider: PhotoProvider {
    var auth: FeedHealth.Authorization
    var album: [AssetValues]
    var other: [AssetValues] = []
    var error: (any Error)?
    init(auth: FeedHealth.Authorization = .authorized, album: [AssetValues] = [], error: (any Error)? = nil) {
        self.auth = auth
        self.album = album
        self.error = error
    }
    func set(auth: FeedHealth.Authorization) { self.auth = auth }
    func set(album: [AssetValues]) { self.album = album }
    func authorization() async -> FeedHealth.Authorization { auth }
    func albumAssets(title: String) async throws -> [AssetValues] {
        if let error { throw error }
        return album
    }
    func oldestCreationDate() async -> Date? { nil }
    func assets(in ranges: [DateInterval]) async throws -> [AssetValues] { other }
}

private struct NoPlaces: PlaceLookup {
    func places(for ids: [String]) async -> [String: PlaceInfo] { [:] }
}

private struct StubFocus: FocusLookup {
    var entries: [String: FocusEntry] = [:]
    func focus(for ids: [String]) async -> [String: FocusEntry] { entries.filter { ids.contains($0.key) } }
}

private func feed(_ p: any PhotoProvider, focus: any FocusLookup = StubFocus()) -> PhotosFeed {
    PhotosFeed(config: PhotosConfig(album: "Frame"), provider: p, lookup: NoPlaces(), focusLookup: focus, logger: Logger(label: "test"))
}

private func get(_ app: some ApplicationProtocol, _ uri: String, headers: HTTPFields = TestAuth.headers) async throws -> (HTTPResponse.Status, String) {
    try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, String(buffer: $0.body)) }
    }
}

private func app(_ f: PhotosFeed) -> some ApplicationProtocol {
    Application(router: buildRouter(config: TestAuth.config, photos: f))
}

private let sample = [asset("AAAA-0000/L0/001", fav: true), asset("BBBB-0000/L0/001", w: 3000, h: 4000)]

@Test func photosServesListWithoutNull() async throws {
    let (status, body) = try await get(app(feed(StubProvider(album: sample))), "/api/photos")
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let photos = try JSONDecoder().decode([Photo].self, from: Data(body.utf8))
    #expect(Set(photos.map(\.id)) == ["AAAA-0000/L0/001", "BBBB-0000/L0/001"])
    #expect(photos.first { $0.id.hasPrefix("BBBB") }?.o == .p)
    #expect(photos.first { $0.id.hasPrefix("AAAA") }?.fav == true)
}

@Test func photosRequireToken() async throws {
    let (status, _) = try await get(app(feed(StubProvider())), "/api/photos", headers: [:])
    #expect(status == .unauthorized)
}

@Test func photosIs503WhenSourceIsDown() async throws {
    let cases: [(StubProvider, String)] = [
        (StubProvider(auth: .denied), "Privacy & Security → Photos"),
        (StubProvider(auth: .restricted), "photos access not granted"),
        (StubProvider(auth: .notDetermined), "photos access not granted"),
        (StubProvider(error: PhotoSourceError.albumNotFound), "album not found"),
        (StubProvider(error: CocoaError(.fileReadUnknown)), "photos read failed"),
    ]
    for (p, detail) in cases {
        let (status, body) = try await get(app(feed(p)), "/api/photos")
        #expect(status == .serviceUnavailable)
        #expect(body.contains("source_unavailable") && body.contains(detail))
    }
    let none = Application(router: buildRouter(config: TestAuth.config))
    let (status, body) = try await get(none, "/api/photos")
    #expect(status == .serviceUnavailable && body.contains("not configured"))
}

@Test func limitedAuthorizationServesAndIsHealthy() async throws {
    let a = app(feed(StubProvider(auth: .limited, album: sample)))
    let (status, _) = try await get(a, "/api/photos")
    #expect(status == .ok)
    let (_, body) = try await get(a, "/healthz")
    let h = try JSONDecoder().decode(Health.self, from: Data(body.utf8)).feeds.photos
    #expect(h.status == .ok && h.authorization == .limited)
}

@Test func healthReportsPhotosState() async throws {
    let ok = app(feed(StubProvider(album: sample)))
    _ = try await get(ok, "/api/photos")
    let (_, okBody) = try await get(ok, "/healthz")
    let h = try JSONDecoder().decode(Health.self, from: Data(okBody.utf8)).feeds.photos
    #expect(h.status == .ok && h.authorization == .authorized && h.staleAfterSeconds == 172800 && h.updatedAt != nil)
    #expect(!okBody.contains("null"))

    let denied = app(feed(StubProvider(auth: .denied)))
    let (_, deniedBody) = try await get(denied, "/healthz")
    let d = try JSONDecoder().decode(Health.self, from: Data(deniedBody.utf8)).feeds.photos
    #expect(d.status == .error && d.authorization == .denied && d.detail?.contains("Privacy & Security → Photos") == true)

    let (_, noneBody) = try await get(Application(router: buildRouter(config: TestAuth.config)), "/healthz")
    let n = try JSONDecoder().decode(Health.self, from: Data(noneBody.utf8)).feeds.photos
    #expect(n.detail == "not configured" && n.authorization == nil && n.staleAfterSeconds == 172800)
}

@Test func switchingAccessOnNeedsNoRestart() async throws {
    let p = StubProvider(auth: .denied, album: sample)
    let a = app(feed(p))
    #expect(try await get(a, "/api/photos").0 == .serviceUnavailable)
    await p.set(auth: .authorized)
    #expect(try await get(a, "/api/photos").0 == .ok)
}

@Test func photosRebuildReportsChangesOnly() async throws {
    let p = StubProvider(album: sample)
    let f = feed(p)
    #expect(await f.rebuild() == false)
    #expect(await f.rebuild() == false)
    await p.set(album: sample + [asset("CCCC-0000/L0/001")])
    // A GET between rebuilds must not swallow the change.
    _ = try await f.list()
    #expect(await f.rebuild() == true)
    #expect(await f.rebuild() == false)
}

@Test func changedRebuildEmitsPhotosEvent() async throws {
    let p = StubProvider(album: sample)
    let f = feed(p)
    let hub = EventHub()
    let sub = await hub.subscribe()
    let debouncer = EventStoreDebouncer(interval: .milliseconds(10))
    await debouncer.subscribe { if await f.rebuild() { await hub.photosChanged() } }
    _ = await f.rebuild()
    await p.set(album: sample + [asset("CCCC-0000/L0/001")])
    await debouncer.poke()
    var it = sub.stream.makeAsyncIterator()
    let message = await it.next()
    #expect(message?.contains("event: photos") == true)
}

@Test func uncachedLocatedListsOnlyLocatedWithoutEntry() async throws {
    let f = feed(StubProvider(album: [asset("A", lat: 1, lon: 2), asset("B")]))
    _ = await f.rebuild()
    #expect(await f.uncachedLocated().map(\.id) == ["A"])
}

@Test func photosServeFocusOnlyWhenCached() async throws {
    let focus = StubFocus(entries: [
        "AAAA-0000/L0/001": FocusEntry(focus: PhotoFocus(x: 0.1, y: 0.2, w: 0.3, h: 0.4)),
        "BBBB-0000/L0/001": FocusEntry(focus: nil),
    ])
    let (status, body) = try await get(app(feed(StubProvider(album: sample + [asset("CCCC-0000/L0/001")]), focus: focus)), "/api/photos")
    #expect(status == .ok)
    #expect(!body.contains("null"))
    let photos = try JSONDecoder().decode([Photo].self, from: Data(body.utf8))
    #expect(photos.first { $0.id == "AAAA-0000/L0/001" }?.focus == PhotoFocus(x: 0.1, y: 0.2, w: 0.3, h: 0.4))
    #expect(photos.filter { $0.focus == nil }.count == 2)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]])
    let withFocus = json.filter { $0["focus"] != nil }
    #expect(withFocus.count == 1)
    #expect(Set((withFocus[0]["focus"] as? [String: Double] ?? [:]).keys) == ["x", "y", "w", "h"])
}

private actor MutableFocus: FocusLookup {
    var entries: [String: FocusEntry] = [:]
    func set(_ entry: FocusEntry, for id: String) { entries[id] = entry }
    func focus(for ids: [String]) async -> [String: FocusEntry] { entries.filter { ids.contains($0.key) } }
}

@Test func newFocusMakesRebuildReportAChange() async throws {
    let lookup = MutableFocus()
    let f = feed(StubProvider(album: sample), focus: lookup)
    #expect(await f.rebuild() == false)
    #expect(await f.rebuild() == false)
    await lookup.set(FocusEntry(focus: PhotoFocus(x: 0, y: 0, w: 0.5, h: 0.5)), for: "AAAA-0000/L0/001")
    #expect(await f.rebuild() == true)
}

@Test func unfocusedListsOnlyIDsWithoutEntry() async throws {
    let focus = StubFocus(entries: ["AAAA-0000/L0/001": FocusEntry(focus: nil)])
    let f = feed(StubProvider(album: sample), focus: focus)
    _ = await f.rebuild()
    #expect(await f.unfocused() == ["BBBB-0000/L0/001"])
}
