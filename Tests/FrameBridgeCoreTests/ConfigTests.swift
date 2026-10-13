import Foundation
import Testing

@testable import FrameBridgeCore

private func json(_ frames: String) -> Data { Data("{\"frames\":\(frames),\"dashboardDir\":\"/tmp/dist\"}".utf8) }
private let good = TestAuth.hex(sha256: UUID().uuidString)

@Test func configLoadsValidFile() throws {
    let config = try Config.decode(json("{\"kitchen\":\"\(good)\"}"))
    #expect(config.frames == ["kitchen": good])
}

@Test func configIgnoresUnknownKeys() throws {
    let data = Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"other\":\"x\"}".utf8)
    #expect(try Config.decode(data).frames.count == 1)
}

@Test func configRejectsMalformed() {
    #expect(throws: ConfigError.self) { try Config.decode(Data("nope".utf8)) }
    #expect(throws: ConfigError.self) { try Config.decode(Data("{}".utf8)) }
}

@Test func configRejectsEmptyFrames() {
    #expect(throws: ConfigError.noFrames) { try Config.decode(json("{}")) }
}

@Test func configRejectsBadHashes() {
    let bad = [
        String(good.dropLast()),
        good + "a",
        good.uppercased() == good ? good + "A" : good.uppercased(),
        String(good.dropLast()) + "g",
    ]
    for hash in bad {
        #expect(throws: ConfigError.badHash(frame: "kitchen")) {
            try Config.decode(json("{\"kitchen\":\"\(hash)\"}"))
        }
    }
}

@Test func configErrorsNeverShowHash() {
    #expect(!ConfigError.badHash(frame: "kitchen").description.contains(good))
}

@Test func configRequiresAbsoluteDashboardDir() throws {
    let frames = "{\"frames\":{\"kitchen\":\"\(good)\"}"
    for extra in ["", ",\"dashboardDir\":\"\"", ",\"dashboardDir\":\"dist\""] {
        #expect(throws: ConfigError.self) { try Config.decode(Data((frames + extra + "}").utf8)) }
    }
    let ok = try Config.decode(Data((frames + ",\"dashboardDir\":\"/srv/dist\"}").utf8))
    #expect(ok.dashboardDir == "/srv/dist")
}

private func withWeather(_ weather: String) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"weather\":\(weather)}".utf8)
}

@Test func weatherIsOptionalAndParses() throws {
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).weather == nil)
    let c = try Config.decode(withWeather("{\"latitude\":0.0,\"longitude\":0.0,\"unit\":\"fahrenheit\"}"))
    #expect(c.weather?.unit == .fahrenheit)
}

@Test func weatherRejectsBadUnitAndRange() {
    #expect(throws: ConfigError.self) { try Config.decode(withWeather("{\"latitude\":0,\"longitude\":0,\"unit\":\"kelvin\"}")) }
    #expect(throws: ConfigError.badWeather(field: "latitude")) {
        try Config.decode(withWeather("{\"latitude\":91,\"longitude\":0,\"unit\":\"celsius\"}"))
    }
    #expect(throws: ConfigError.badWeather(field: "longitude")) {
        try Config.decode(withWeather("{\"latitude\":0,\"longitude\":181,\"unit\":\"celsius\"}"))
    }
}
