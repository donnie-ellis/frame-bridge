import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The spec's `size` query: `half` is 640, anything else (missing or invalid) is `full`, 1280.
enum ImageSize: String {
    case full, half

    init(query: String?) {
        self = query == "half" ? .half : .full
    }

    var maxEdge: Int { self == .half ? 640 : 1280 }
}

enum ImageSizing {
    /// Keeps the aspect ratio. Never upscales.
    static func targetSize(width: Int, height: Int, maxEdge: Int) -> (w: Int, h: Int) {
        let long = max(width, height)
        guard long > maxEdge, long > 0 else { return (max(width, 1), max(height, 1)) }
        let scale = Double(maxEdge) / Double(long)
        return (max(Int((Double(width) * scale).rounded()), 1), max(Int((Double(height) * scale).rounded()), 1))
    }

    static func idHash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Photo ids contain `/`, so the file name is a hash of the id. The prefix lets pruning go by id.
    static func cacheFileName(id: String, size: ImageSize) -> String {
        "\(idHash(id))-\(size.rawValue).jpg"
    }

    struct EncodeError: Error {}

    static func jpeg(from image: CGImage, maxEdge: Int, quality: Double = 0.8) throws -> Data {
        var output = image
        let target = targetSize(width: image.width, height: image.height, maxEdge: maxEdge)
        if target.w != image.width || target.h != image.height {
            guard let context = CGContext(
                data: nil, width: target.w, height: target.h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw EncodeError() }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: target.w, height: target.h))
            guard let scaled = context.makeImage() else { throw EncodeError() }
            output = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw EncodeError() }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError() }
        return data as Data
    }
}
