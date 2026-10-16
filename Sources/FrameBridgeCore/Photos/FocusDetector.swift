import CoreGraphics
import Foundation
@preconcurrency import Vision

protocol FocusDetecting: Sendable {
    /// Nil when nothing was found. Throws when Vision fails (not cached, retried later).
    func focus(in image: CGImage) async throws -> PhotoFocus?
}

/// Faces, then people, then saliency (see `FocusMapping`). Runs off the cooperative pool.
struct VisionFocusDetector: FocusDetecting {
    func focus(in image: CGImage) async throws -> PhotoFocus? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                continuation.resume(with: Result { try Self.detect(image) })
            }
        }
    }

    private static func detect(_ image: CGImage) throws -> PhotoFocus? {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)

        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        try handler.perform([faces, humans])
        let faceBoxes = (faces.results ?? []).map { ScoredBox(rect: $0.boundingBox, confidence: $0.confidence) }
        let humanBoxes = (humans.results ?? []).map { ScoredBox(rect: $0.boundingBox, confidence: $0.confidence) }

        // Saliency only when no face or person is confident enough.
        var objectBoxes: [ScoredBox] = []
        if FocusMapping.faceBoxes(faceBoxes).isEmpty, FocusMapping.confident(humanBoxes, min: FocusMapping.humanMinConfidence).isEmpty {
            let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
            try handler.perform([objectness])
            objectBoxes = scored(objectness.results)
        }

        let selected = try FocusMapping.select(faces: faceBoxes, humans: humanBoxes, objectness: objectBoxes) {
            let attention = VNGenerateAttentionBasedSaliencyImageRequest()
            try handler.perform([attention])
            return scored(attention.results)
        }
        return FocusMapping.focus(fromVisionBoxes: selected)
    }

    private static func scored(_ results: [VNSaliencyImageObservation]?) -> [ScoredBox] {
        (results ?? []).flatMap { $0.salientObjects ?? [] }.map { ScoredBox(rect: $0.boundingBox, confidence: $0.confidence) }
    }
}
