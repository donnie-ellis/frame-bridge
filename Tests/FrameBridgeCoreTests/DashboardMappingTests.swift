import Foundation
import Testing

@testable import FrameBridgeCore

@Test func cacheControlByPath() {
    for path in ["/", "/index.html", "/manifest.webmanifest", "/icon-192.png", "/assetsfoo.js"] {
        #expect(DashboardFilesMiddleware.cacheControl(forPath: path) == "no-cache")
    }
    #expect(DashboardFilesMiddleware.cacheControl(forPath: "/assets/x.js") == "public, max-age=31536000, immutable")
}

@Test func directoryStatusCases() throws {
    let dir = try DashboardTestDir()
    defer { dir.remove() }
    #expect(DashboardFilesMiddleware.directoryStatus(dir.base.appendingPathComponent("nope").path) == .missing)
    #expect(DashboardFilesMiddleware.directoryStatus(dir.dist.path) == .ready)
    let empty = dir.base.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(DashboardFilesMiddleware.directoryStatus(empty.path) == .empty)
}
