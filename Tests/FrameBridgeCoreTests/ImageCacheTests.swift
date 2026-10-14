import Foundation
import Testing

@testable import FrameBridgeCore

@Test func secondCallIsServedFromDisk() async throws {
    let source = StubImageSource()
    let cache = ImageCache(directory: tempDir(), source: source)
    let a = try await cache.jpeg(id: "A/L0/001", size: .full)
    let b = try await cache.jpeg(id: "A/L0/001", size: .full)
    #expect(a == b)
    #expect(await source.calls.count == 1)
}

@Test func concurrentCallsShareOneRender() async throws {
    let source = StubImageSource()
    await source.set(delay: .milliseconds(100))
    let cache = ImageCache(directory: tempDir(), source: source)
    async let x = cache.jpeg(id: "A", size: .half)
    async let y = cache.jpeg(id: "A", size: .half)
    _ = try await (x, y)
    #expect(await source.calls.count == 1)
}

@Test func failureWritesNothingAndIsNotMemoized() async throws {
    let dir = tempDir()
    let source = StubImageSource()
    await source.set(fail: true)
    let cache = ImageCache(directory: dir, source: source)
    await #expect(throws: APIError.self) { try await cache.jpeg(id: "A", size: .full) }
    #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    await source.set(fail: false)
    _ = try await cache.jpeg(id: "A", size: .full)
    #expect(await source.calls.count == 2)
}

@Test func pruneKeepsBothSizesOfKeptIds() async throws {
    let dir = tempDir()
    let source = StubImageSource()
    let cache = ImageCache(directory: dir, source: source)
    for id in ["A", "B"] { for size in [ImageSize.full, .half] { _ = try await cache.jpeg(id: id, size: size) } }
    await cache.prune(keeping: ["A"])
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    #expect(names == [ImageSizing.cacheFileName(id: "A", size: .full), ImageSizing.cacheFileName(id: "A", size: .half)])
}
