import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import FrameBridgeCore

// Hand check, needs Vision (not the real Photos library): FRAME_BRIDGE_VISION_CHECK=1 swift test --filter visionFocus
private let visionCheck = ProcessInfo.processInfo.environment["FRAME_BRIDGE_VISION_CHECK"] != nil

@Test(.enabled(if: visionCheck)) func visionFocusContainsTheSyntheticSubject() async throws {
    let subject = CGRect(x: 0.5, y: 0.3, width: 0.3, height: 0.4)
    let focus = try #require(try await VisionFocusDetector().focus(in: makeSubjectImage(w: 1280, h: 960, subject: subject)))
    print("synthetic focus: \(focus)")
    #expect(focus.x <= subject.minX && focus.y <= subject.minY)
    #expect(focus.x + focus.w >= subject.maxX && focus.y + focus.h >= subject.maxY)
    #expect(focus.x + focus.w <= 1 && focus.y + focus.h <= 1)
}

@Test(.enabled(if: visionCheck)) func visionFocusTimingOnStockPictures() async throws {
    let root = URL(fileURLWithPath: "/Library/User Pictures")
    let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { ["png", "jpg", "jpeg", "tif", "heic"].contains($0.pathExtension.lowercased()) }
    guard !files.isEmpty else { print("no stock pictures"); return }
    let detector = VisionFocusDetector()
    var found = 0
    let start = ContinuousClock.now
    for file in files {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
        if try await detector.focus(in: image) != nil { found += 1 }
    }
    let elapsed = ContinuousClock.now - start
    print("stock pictures: \(files.count) images, \(found) with focus, \(elapsed / files.count) per image")
}
