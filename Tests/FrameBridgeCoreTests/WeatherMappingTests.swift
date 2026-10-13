import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!

@Test func mapsFixtureToFortyEightEntries() throws {
    let (w, unknown) = try WeatherMapping.map(WeatherFixture.forecast(), timeZone: ny)
    #expect(w.t.count == 48 && w.c.count == 48 && w.p.count == 48)
    #expect(w.start == "2026-10-13T00:00:00-04:00")
    #expect(w.hi == 17 && w.lo == 8)
    #expect(w.p[3] == 0 && w.p[47] == 0)
    #expect(w.c[0] == .moon && w.c[9] == .partly && w.c[31] == .sun)
    #expect(unknown.isEmpty)
}

@Test(arguments: [
    (0, WeatherCondition.sun), (1, .sun), (2, .partly), (3, .cloud), (45, .cloud), (48, .cloud),
    (51, .rain), (67, .rain), (80, .rain), (82, .rain), (71, .snow), (77, .snow), (85, .snow),
    (86, .snow), (95, .storm), (99, .storm),
])
func conditionTable(code: Int, expected: WeatherCondition) {
    let night: WeatherCondition = expected == .sun ? .moon : expected
    #expect(WeatherMapping.condition(code: code, isDay: true) == expected)
    #expect(WeatherMapping.condition(code: code, isDay: false) == night)
}

@Test func unknownCodesBecomeCloudAndAreReported() {
    #expect(WeatherMapping.condition(code: 4, isDay: true) == nil)
    #expect(WeatherMapping.condition(code: 100, isDay: true) == nil)
}

private func forecast(hours: Int = 48, temp: Double? = 8.5, code: Int = 4, hi: Double? = 1, lo: Double? = 0, p: Int? = nil) -> OpenMeteoForecast {
    func arr<T>(_ v: T) -> String { "[" + Array(repeating: "\(v)", count: hours).joined(separator: ",") + "]" }
    let tempJSON = temp.map { arr($0) } ?? "[null" + String(repeating: ",1", count: hours - 1) + "]"
    let pJSON = p.map { arr($0) } ?? arr("null")
    let json = """
    {"hourly":{"time":\(arr("\"x\"")),"temperature_2m":\(tempJSON),"precipitation_probability":\(pJSON),
    "weather_code":\(arr(code)),"is_day":\(arr(1))},
    "daily":{"time":["2026-10-13"],"temperature_2m_max":[\(hi.map { "\($0)" } ?? "null")],"temperature_2m_min":[\(lo.map { "\($0)" } ?? "null")]}}
    """
    return try! JSONDecoder().decode(OpenMeteoForecast.self, from: Data(json.utf8))
}

@Test func unknownCodeMapsToCloudAndIsReported() throws {
    let (w, unknown) = try WeatherMapping.map(forecast(), timeZone: ny)
    #expect(w.c.allSatisfy { $0 == .cloud })
    #expect(unknown == [4])
}

@Test func roundsHalfUpAndNeverNegativeZero() throws {
    #expect(try WeatherMapping.map(forecast(temp: 8.5), timeZone: ny).weather.t[0] == 9)
    let w = try WeatherMapping.map(forecast(temp: -0.4, hi: -0.4, lo: -0.4), timeZone: ny).weather
    #expect(w.t[0] == 0 && w.hi == 0 && w.lo == 0)
    #expect("\(w.t[0])" == "0")
}

@Test func precipitationClamped() throws {
    #expect(try WeatherMapping.map(forecast(p: 130), timeZone: ny).weather.p[0] == 100)
}

@Test func tooFewHoursThrowsAndExtraHoursAreTruncated() throws {
    #expect(throws: WeatherMappingError.tooFewHours(47)) { try WeatherMapping.map(forecast(hours: 47), timeZone: ny) }
    #expect(try WeatherMapping.map(forecast(hours: 72), timeZone: ny).weather.t.count == 48)
}

@Test func missingValuesThrow() {
    #expect(throws: WeatherMappingError.missingValue) { try WeatherMapping.map(forecast(temp: nil), timeZone: ny) }
    #expect(throws: WeatherMappingError.missingValue) { try WeatherMapping.map(forecast(hi: nil), timeZone: ny) }
}

@Test func wireDateUsesOffsetNotZ() {
    let date = Date(timeIntervalSince1970: 1_791_000_000)
    let s = WireDate.string(from: date, timeZone: ny)
    #expect(s.hasSuffix("-04:00") || s.hasSuffix("-05:00"))
    #expect(!s.hasSuffix("Z"))
    #expect(WireDate.string(from: date, timeZone: TimeZone(identifier: "Asia/Kolkata")!).hasSuffix("+05:30"))
}
