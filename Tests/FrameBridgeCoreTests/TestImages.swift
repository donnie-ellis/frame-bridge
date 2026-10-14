import CoreGraphics
import Foundation

@testable import FrameBridgeCore

func makeImage(_ w: Int, _ h: Int) -> CGImage {
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage()!
}

actor StubImageSource: ImageSource {
    private(set) var calls: [(id: String, maxEdge: Int)] = []
    var fail = false
    var delay: Duration = .zero
    func set(fail: Bool) { self.fail = fail }
    func set(delay: Duration) { self.delay = delay }
    func image(id: String, maxEdge: Int) async throws -> CGImage {
        calls.append((id, maxEdge))
        if delay > .zero { try await Task.sleep(for: delay) }
        if fail { throw PhotoImageError() }
        return makeImage(2000, 1000)
    }
}

func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fb-images-\(UUID().uuidString)")
}
