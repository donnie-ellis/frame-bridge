import CoreGraphics
import Foundation
import Testing

@testable import FrameBridgeCore

private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Float = 1) -> ScoredBox {
    ScoredBox(rect: CGRect(x: x, y: y, width: w, height: h), confidence: c)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Test func focusIsThePaddedUnionOfTheBoxes() throws {
    let f = try #require(FocusMapping.focus(fromVisionBoxes: [CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.1), CGRect(x: 0.5, y: 0.4, width: 0.1, height: 0.2)]))
    #expect(near(f.x, 0.2 - 0.035))
    #expect(near(f.w, 0.4 + 0.07))
    // Union is y 0.3...0.6, padded 0.265...0.635, flipped: 1 - 0.635.
    #expect(near(f.y, 1 - 0.635))
    #expect(near(f.h, 0.3 + 0.07))
}

@Test func visionYIsFlippedToTopLeft() throws {
    // Without padding room issues: y 0.7, h 0.2 is y 0.1 from the top.
    let f = try #require(FocusMapping.focus(fromVisionBoxes: [CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.2)]))
    #expect(near(f.y, 0.1 - 0.035))
}

@Test func paddingIsClippedAtEveryEdge() throws {
    let left = try #require(FocusMapping.focus(fromVisionBoxes: [CGRect(x: 0.01, y: 0.4, width: 0.2, height: 0.2)]))
    #expect(left.x == 0)
    let right = try #require(FocusMapping.focus(fromVisionBoxes: [CGRect(x: 0.8, y: 0.4, width: 0.19, height: 0.2)]))
    #expect(right.x + right.w <= 1)
    #expect(near(right.x + right.w, 1))
    let bottom = try #require(FocusMapping.focus(fromVisionBoxes: [CGRect(x: 0.4, y: 0.01, width: 0.2, height: 0.2)]))
    #expect(near(bottom.y + bottom.h, 1))
    let top = try #require(FocusMapping.focus(fromVisionBoxes: [CGRect(x: 0.4, y: 0.8, width: 0.19, height: 0.19)]))
    #expect(top.y == 0)
}

@Test func cornerBoxesStayInsideTheImage() throws {
    for r in [CGRect(x: 0, y: 0, width: 0.1, height: 0.1), CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1), CGRect(x: 0, y: 0, width: 1, height: 1)] {
        let f = try #require(FocusMapping.focus(fromVisionBoxes: [r]))
        #expect(f.x >= 0 && f.y >= 0)
        #expect(f.x + f.w <= 1)
        #expect(f.y + f.h <= 1)
    }
}

@Test func emptyOrZeroAreaIsNil() {
    #expect(FocusMapping.focus(fromVisionBoxes: []) == nil)
    #expect(FocusMapping.focus(fromVisionBoxes: [CGRect(x: 2, y: 2, width: 0.1, height: 0.1)]) == nil)
}

@Test func facesBelowSixtyPercentAreDropped() {
    #expect(FocusMapping.faceBoxes([box(0.4, 0.4, 0.1, 0.1, 0.59)]).isEmpty)
    #expect(FocusMapping.faceBoxes([box(0.4, 0.4, 0.1, 0.1, 0.6)]).count == 1)
}

@Test func facesGrowAroundTheirCentre() throws {
    let r = try #require(FocusMapping.faceBoxes([box(0.4, 0.4, 0.2, 0.2)]).first)
    #expect(near(Double(r.width), 0.3))
    #expect(near(Double(r.height), 0.33))
    #expect(near(Double(r.midX), 0.5))
    #expect(near(Double(r.midY), 0.5))
}

@Test func coverageIsTheClippedUnionBounds() {
    #expect(FocusMapping.coversTooMuch([CGRect(x: 0, y: 0, width: 0.9, height: 1)]))
    #expect(!FocusMapping.coversTooMuch([CGRect(x: 0, y: 0, width: 0.85, height: 1)]))
    #expect(FocusMapping.coversTooMuch([CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]))
    #expect(!FocusMapping.coversTooMuch([]))
}

@Test func facesBeatHumans() throws {
    let r = try FocusMapping.select(faces: [box(0.4, 0.4, 0.1, 0.1)], humans: [box(0, 0, 1, 1)], objectness: [], attention: { Issue.record("attention ran"); return [] })
    #expect(r.count == 1)
    #expect(near(Double(r[0].width), 0.15))
}

@Test func lowConfidenceFacesFallToHumans() throws {
    let r = try FocusMapping.select(faces: [box(0.4, 0.4, 0.1, 0.1, 0.5)], humans: [box(0.1, 0.1, 0.3, 0.8)], objectness: [], attention: { [] })
    #expect(r == [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.8)])
}

@Test func objectnessIsUsedWithoutAttentionWhenItIsSmall() throws {
    let r = try FocusMapping.select(faces: [], humans: [box(0, 0, 1, 1, 0.5)], objectness: [box(0.2, 0.2, 0.3, 0.3, 0.5), box(0.6, 0.6, 0.1, 0.1, 0.4)], attention: { Issue.record("attention ran"); return [] })
    #expect(r == [CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)])
}

@Test func hugeObjectnessUsesAttention() throws {
    var ran = false
    let r = try FocusMapping.select(faces: [], humans: [], objectness: [box(0, 0, 1, 1)], attention: {
        ran = true
        return [box(0.3, 0.3, 0.2, 0.2, 0.5), box(0.6, 0.6, 0.1, 0.1, 0.49)]
    })
    #expect(ran)
    #expect(r == [CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)])
}

@Test func noConfidentObjectnessIsNothingFoundWithoutAttention() throws {
    let r = try FocusMapping.select(faces: [], humans: [], objectness: [box(0.2, 0.2, 0.3, 0.3, 0.49)], attention: { Issue.record("attention ran"); return [] })
    #expect(r.isEmpty)
}

@Test func nothingDetectedIsEmpty() throws {
    #expect(try FocusMapping.select(faces: [], humans: [], objectness: [], attention: { [] }).isEmpty)
}

@Test func attentionFindingNothingDiscardsTheHugeObjectness() throws {
    #expect(try FocusMapping.select(faces: [], humans: [], objectness: [box(0, 0, 1, 1)], attention: { [] }).isEmpty)
}
