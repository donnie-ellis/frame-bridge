import Foundation
import Testing

@testable import FrameBridgeCore

@Test func placeCacheRoundTripsIncludingNegativeEntries() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = PlaceCache(directory: dir)
    #expect(await first.places(for: ["a"]).isEmpty)
    try await first.store(PlaceInfo(place: "Madeupville", timeZone: "UTC"), for: "a")
    try await first.store(PlaceInfo(place: nil, timeZone: nil), for: "b")
    let second = PlaceCache(directory: dir)
    let loaded = await second.places(for: ["a", "b", "c"])
    #expect(loaded == ["a": PlaceInfo(place: "Madeupville", timeZone: "UTC"), "b": PlaceInfo(place: nil, timeZone: nil)])
}
