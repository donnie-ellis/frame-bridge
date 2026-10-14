import Foundation
import ImageIO
import Testing

@testable import FrameBridgeCore

@Test func targetSizeKeepsAspectAndNeverUpscales() {
    #expect(ImageSizing.targetSize(width: 2048, height: 1536, maxEdge: 1280) == (1280, 960))
    #expect(ImageSizing.targetSize(width: 1536, height: 2048, maxEdge: 640) == (480, 640))
    #expect(ImageSizing.targetSize(width: 2048, height: 2048, maxEdge: 1280) == (1280, 1280))
    #expect(ImageSizing.targetSize(width: 800, height: 600, maxEdge: 1280) == (800, 600))
    #expect(ImageSizing.targetSize(width: 1281, height: 1, maxEdge: 1280) == (1280, 1))
}

@Test func cacheFileNameHasNoSlashAndDiffersPerSize() {
    let id = "B7E1A2C3-0000-4000-8000-000000000001/L0/001"
    let full = ImageSizing.cacheFileName(id: id, size: .full)
    #expect(!full.contains("/"))
    #expect(full == ImageSizing.cacheFileName(id: id, size: .full))
    #expect(full != ImageSizing.cacheFileName(id: id, size: .half))
}

private func decodedSize(_ data: Data) -> (Int, Int)? {
    guard let s = CGImageSourceCreateWithData(data as CFData, nil), let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
    return (i.width, i.height)
}

@Test func jpegResizesAndEncodes() throws {
    let data = try ImageSizing.jpeg(from: makeImage(2048, 1024), maxEdge: 1280)
    #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
    #expect(decodedSize(data)! == (1280, 640))
    let small = try ImageSizing.jpeg(from: makeImage(300, 200), maxEdge: 1280)
    #expect(decodedSize(small)! == (300, 200))
}

@Test func imageSizeParsing() {
    #expect(ImageSize(query: nil) == .full)
    #expect(ImageSize(query: "full") == .full)
    #expect(ImageSize(query: "half") == .half)
    #expect(ImageSize(query: "huge") == .full)
}
