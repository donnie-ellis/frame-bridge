import Foundation

/// tmp/<uuid>/dist with an index and one hashed asset, plus a secret outside dist and a symlink to it.
struct DashboardTestDir {
    static let indexMarker = "INDEX-MARKER-\(UUID().uuidString)"
    static let secret = "SECRET-\(UUID().uuidString)"

    let base: URL
    var dist: URL { base.appendingPathComponent("dist") }

    init() throws {
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dist.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<html>\(Self.indexMarker)</html>".write(to: dist.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: dist.appendingPathComponent("assets/app-abc123.js"), atomically: true, encoding: .utf8)
        try Self.secret.write(to: base.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: dist.appendingPathComponent("link.txt"), withDestinationURL: base.appendingPathComponent("secret.txt"))
        try "not health".write(to: dist.appendingPathComponent("healthz"), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}
