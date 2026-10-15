import Testing

@testable import FrameBridgeCore

private let schema = HueLight.ColorTemperature.Schema.init(mirekMinimum: 153, mirekMaximum: 500)
private let gamutC = HueLight.Color.Gamut(
    red: .init(x: 0.6915, y: 0.3083), green: .init(x: 0.17, y: 0.7), blue: .init(x: 0.1532, y: 0.0475))
private let d65 = HueLight.XY(x: 0.3127, y: 0.3290)

@Test func kelvinAndRange() {
    #expect(LightColor.kelvin(mirek: 370) == 2703)
    #expect(LightColor.tempRange(schema) == Light.TempRange(min: 2000, max: 6536))
}

@Test func mirekForKelvinIsClamped() {
    #expect(LightColor.mirek(forKelvin: 2700, schema: schema) == 370)
    #expect(LightColor.mirek(forKelvin: 10000, schema: schema) == 153)
    #expect(LightColor.mirek(forKelvin: 1000, schema: schema) == 500)
    #expect(LightColor.mirek(forKelvin: 0, schema: schema) == 500)
    #expect(LightColor.mirek(forKelvin: -5, schema: schema) == 500)
}

private func channels(_ hex: String) -> [Int] {
    let v = Int(hex.dropFirst(), radix: 16) ?? 0
    return [(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]
}

@Test func whitePointIsNearWhiteAndLowerBrightnessIsDarker() {
    let white = LightColor.hex(xy: d65, brightness: 100, gamut: gamutC)
    #expect(channels(white).allSatisfy { $0 >= 250 })
    let dim = LightColor.hex(xy: d65, brightness: 20, gamut: gamutC)
    #expect(channels(dim)[0] < channels(white)[0])
}

@Test func hexIsLowercaseAndMatchesThePattern() {
    for xy in [d65, HueLight.XY(x: 0.6915, y: 0.3083), HueLight.XY(x: 0.1532, y: 0.0475), HueLight.XY(x: 0.9, y: 0.05)] {
        let hex = LightColor.hex(xy: xy, brightness: nil, gamut: gamutC)
        #expect(hex.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil)
    }
}

@Test func outOfGamutEqualsItsClampedPoint() {
    let outside = HueLight.XY(x: 0.9, y: 0.05)
    let hex = LightColor.hex(xy: outside, brightness: 100, gamut: gamutC)
    // The closest point on the red-blue edge is inside, and gives a different colour than unclamped.
    #expect(hex != LightColor.hex(xy: outside, brightness: 100, gamut: nil))
    let onEdge = LightColor.hex(xy: gamutC.red, brightness: 100, gamut: gamutC)
    #expect(LightColor.hex(xy: gamutC.red, brightness: 100, gamut: nil) == onEdge)
}

@Test func hexRoundTripsWithinTolerance() throws {
    for hex in ["#ff8a3d", "#3366ff", "#80ff00", "#ffffff"] {
        let xy = try #require(LightColor.xy(hex: hex))
        let back = LightColor.hex(xy: xy, brightness: 100, gamut: nil)
        let a = channels(hex), b = channels(back)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) <= 3 }, "\(hex) -> \(back)")
    }
    #expect(LightColor.xy(hex: "#000000") == nil)
}
