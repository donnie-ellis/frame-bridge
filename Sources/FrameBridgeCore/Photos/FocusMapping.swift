import CoreGraphics
import Foundation

/// A Vision detection: normalized rect with a bottom-left origin, and its confidence.
struct ScoredBox: Sendable, Equatable {
    var rect: CGRect
    var confidence: Float
}

/// Vision boxes -> `PhotoFocus`. Pure, so the rules are tested without Vision.
///
///  Step | Source                                   | Keep           | Then
///  1    | faces                                    | confidence 0.6 | grow 1.5x wide, 1.65x tall around the centre
///  2    | humans (whole body)                      | confidence 0.6 | only if no faces
///  3    | objectness saliency                      | confidence 0.5 | only if neither; none at all = nothing found
///  4    | attention saliency                       | confidence 0.5 | only if step 3 boxes cover > 85% of the image
///  end  | union, pad 0.035 of the image per side, clip to [0,1], flip y to a top-left origin
enum FocusMapping {
    static let humanMinConfidence: Float = 0.6
    static let saliencyMinConfidence: Float = 0.5
    static let faceGrowWidth = 1.5
    static let faceGrowHeight = 1.65
    static let maxCoverage = 0.85
    static let padding = 0.035

    static func confident(_ boxes: [ScoredBox], min: Float) -> [ScoredBox] {
        boxes.filter { $0.confidence >= min }
    }

    static func faceBoxes(_ faces: [ScoredBox]) -> [CGRect] {
        confident(faces, min: humanMinConfidence).map { f in
            let w = f.rect.width * faceGrowWidth, h = f.rect.height * faceGrowHeight
            return CGRect(x: f.rect.midX - w / 2, y: f.rect.midY - h / 2, width: w, height: h)
        }
    }

    /// Area of the union's bounding rect, clipped to the image, is more than 85% of it.
    static func coversTooMuch(_ rects: [CGRect]) -> Bool {
        guard let box = union(rects) else { return false }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return !clipped.isNull && Double(clipped.width * clipped.height) > maxCoverage
    }

    /// Empty means nothing found. `attention` runs only when objectness covers too much.
    /// When attention finds nothing too, the oversized objectness boxes are discarded (the spec says
    /// to discard them), so nothing is found.
    static func select(faces: [ScoredBox], humans: [ScoredBox], objectness: [ScoredBox], attention: () throws -> [ScoredBox]) rethrows -> [CGRect] {
        let f = faceBoxes(faces)
        if !f.isEmpty { return f }
        let h = confident(humans, min: humanMinConfidence).map(\.rect)
        if !h.isEmpty { return h }
        let o = confident(objectness, min: saliencyMinConfidence).map(\.rect)
        if o.isEmpty { return [] }
        if !coversTooMuch(o) { return o }
        return confident(try attention(), min: saliencyMinConfidence).map(\.rect)
    }

    /// Union, pad, clip, flip. Nil when there is nothing, or the result has no area.
    static func focus(fromVisionBoxes boxes: [CGRect]) -> PhotoFocus? {
        guard let box = union(boxes) else { return nil }
        let x0 = max(0, Double(box.minX) - padding), x1 = min(1, Double(box.maxX) + padding)
        let y0 = max(0, Double(box.minY) - padding), y1 = min(1, Double(box.maxY) + padding)
        guard x1 > x0, y1 > y0 else { return nil }
        // y = 1 - y - h in Vision terms: the top edge becomes the origin.
        let y = 1 - y1
        return PhotoFocus(x: x0, y: y, w: min(x1 - x0, 1 - x0), h: min(y1 - y0, 1 - y))
    }

    private static func union(_ rects: [CGRect]) -> CGRect? {
        rects.first.map { first in rects.dropFirst().reduce(first) { $0.union($1) } }
    }
}
