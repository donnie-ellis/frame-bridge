import Foundation
import Testing

@testable import FrameBridgeCore

@Test func focusCacheRoundTripsIncludingNothingFound() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = FocusCache(directory: dir)
    #expect(await first.focus(for: ["a"]).isEmpty)
    let box = PhotoFocus(x: 0.1, y: 0.2, w: 0.3, h: 0.4)
    try await first.store(FocusEntry(focus: box), for: "a")
    try await first.store(FocusEntry(focus: nil), for: "b")
    let second = FocusCache(directory: dir)
    let loaded = await second.focus(for: ["a", "b", "c"])
    #expect(loaded == ["a": FocusEntry(focus: box), "b": FocusEntry(focus: nil)])
}
