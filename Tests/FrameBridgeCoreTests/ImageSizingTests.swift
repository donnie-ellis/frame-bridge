import Foundation
import ImageIO
import UniformTypeIdentifiers
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

private func jpegData(_ image: CGImage, orientation: Int? = nil) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Test func thumbnailShrinksTheLongEdgeToMaxEdge() throws {
    let image = try #require(ImageSizing.thumbnail(from: jpegData(makeImage(2048, 1536)), maxEdge: 1280))
    #expect(image.width == 1280)
    #expect(image.height == 960)
}

@Test func thumbnailNeverUpscales() throws {
    let image = try #require(ImageSizing.thumbnail(from: jpegData(makeImage(400, 300)), maxEdge: 1280))
    #expect(image.width == 400)
    #expect(image.height == 300)
}

@Test func thumbnailAppliesTheExifOrientation() throws {
    // 6 = rotated 90°: stored landscape, shown portrait.
    let image = try #require(ImageSizing.thumbnail(from: jpegData(makeImage(2048, 1536), orientation: 6), maxEdge: 640))
    #expect(image.width == 480)
    #expect(image.height == 640)
}

@Test func thumbnailOfGarbageIsNil() {
    #expect(ImageSizing.thumbnail(from: Data("not an image".utf8), maxEdge: 640) == nil)
}
