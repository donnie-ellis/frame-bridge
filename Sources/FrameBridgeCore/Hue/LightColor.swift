import Foundation

/// Pure colour maths for Light.temp and Light.color.
///
/// Hue `mirek` <-> Kelvin (`1e6 / x`, rounded), and Hue CIE `xy` + brightness <-> sRGB `#rrggbb`.
/// The sRGB matrices are used both ways, so a colour sent comes back as the same hex.
enum LightColor {
    typealias XY = HueLight.XY

    static func kelvin(mirek: Int) -> Int {
        Int((1_000_000 / Double(max(mirek, 1))).rounded())
    }

    static func tempRange(_ schema: HueLight.ColorTemperature.Schema) -> Light.TempRange {
        Light.TempRange(min: kelvin(mirek: schema.mirekMaximum), max: kelvin(mirek: schema.mirekMinimum))
    }

    /// Clamps to the light's range first, so there is no division by zero.
    static func mirek(forKelvin kelvin: Int, schema: HueLight.ColorTemperature.Schema) -> Int {
        let range = tempRange(schema)
        let k = Double(min(max(kelvin, range.min), range.max))
        let mirek = Int((1_000_000 / k).rounded())
        return min(max(mirek, schema.mirekMinimum), schema.mirekMaximum)
    }

    // MARK: xy -> hex

    static func hex(xy: XY, brightness: Double?, gamut: HueLight.Color.Gamut?) -> String {
        let point = gamut.map { clamp(xy, to: $0) } ?? xy
        let y = min(max((brightness ?? 100) / 100, 0), 1)
        guard point.y > 0 else { return "#000000" }
        let bigY = y
        let x = bigY / point.y * point.x
        let z = bigY / point.y * (1 - point.x - point.y)
        var rgb = [
            3.2404542 * x - 1.5371385 * bigY - 0.4985314 * z,
            -0.9692660 * x + 1.8760108 * bigY + 0.0415560 * z,
            0.0556434 * x - 0.2040259 * bigY + 1.0572252 * z,
        ].map { max($0, 0) }
        if let top = rgb.max(), top > 1 { rgb = rgb.map { $0 / top } }
        let bytes = rgb.map { Int((gamma(min($0, 1)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", bytes[0], bytes[1], bytes[2])
    }

    /// The chromaticity of a `#rrggbb`; nil for black, which has none.
    static func xy(hex: String) -> XY? {
        let digits = hex.dropFirst()
        guard hex.hasPrefix("#"), digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        let rgb = [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff].map { linear(Double($0) / 255) }
        let x = 0.4124564 * rgb[0] + 0.3575761 * rgb[1] + 0.1804375 * rgb[2]
        let y = 0.2126729 * rgb[0] + 0.7151522 * rgb[1] + 0.0721750 * rgb[2]
        let z = 0.0193339 * rgb[0] + 0.1191920 * rgb[1] + 0.9503041 * rgb[2]
        let sum = x + y + z
        guard sum > 0 else { return nil }
        return XY(x: x / sum, y: y / sum)
    }

    private static func gamma(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    // MARK: gamut

    private static func clamp(_ p: XY, to g: HueLight.Color.Gamut) -> XY {
        func cross(_ a: XY, _ b: XY, _ c: XY) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        let d1 = cross(g.red, g.green, p), d2 = cross(g.green, g.blue, p), d3 = cross(g.blue, g.red, p)
        let inside = !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
        if inside { return p }
        return [(g.red, g.green), (g.green, g.blue), (g.blue, g.red)]
            .map { closest(p, onSegment: $0.0, $0.1) }
            .min { distance($0, p) < distance($1, p) } ?? p
    }

    private static func closest(_ p: XY, onSegment a: XY, _ b: XY) -> XY {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return a }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0), 1)
        return XY(x: a.x + t * dx, y: a.y + t * dy)
    }

    private static func distance(_ a: XY, _ b: XY) -> Double {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}
