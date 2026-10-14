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

private func withCalendar(_ calendar: String) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"calendar\":\(calendar)}".utf8)
}

@Test func calendarIsOptionalAndParses() throws {
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).calendar == nil)
    let c = try Config.decode(withCalendar("{\"people\":[\"a\",\"b\"],\"calendars\":{\"Family\":\"all\",\"Mine\":[\"a\"]}}"))
    #expect(c.calendar?.people(for: "Family") == ["a", "b"])
    #expect(c.calendar?.people(for: "Mine") == ["a"])
    #expect(c.calendar?.people(for: "Other") == nil)
}

@Test func calendarRejectsBadSections() {
    for bad in [
        "{\"people\":[],\"calendars\":{}}",
        "{\"people\":[\"a\",\"a\"],\"calendars\":{}}",
        "{\"people\":[\"\"],\"calendars\":{}}",
        "{\"people\":[\"a\"],\"calendars\":{\"X\":[]}}",
        "{\"people\":[\"a\"],\"calendars\":{\"X\":[\"zed\"]}}",
        "{\"people\":[\"a\"],\"calendars\":{\"X\":\"everyone\"}}",
    ] {
        #expect(throws: ConfigError.self) { try Config.decode(withCalendar(bad)) }
    }
}

private func withShopping(_ shopping: String) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"shopping\":\(shopping)}".utf8)
}

@Test func shoppingIsOptionalAndParses() throws {
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).shopping == nil)
    let c = try Config.decode(withShopping(#"{"list":"L","stores":[{"id":"a","name":"A"}],"defaultStore":"a"}"#))
    #expect(c.shopping?.storeKeywords == [:] && c.shopping?.categories == [:])
    let full = try Config.decode(withShopping(#"{"list":"L","stores":[{"id":"a","name":"A"},{"id":"b","name":"B"}],"defaultStore":"a","storeKeywords":{"b":["x"]},"categories":{"Produce":["y"]}}"#))
    #expect(full.shopping?.storeKeywords == ["b": ["x"]])
}

@Test func shoppingRejectsBadSections() {
    let s = #""stores":[{"id":"a","name":"A"}]"#
    for bad in [
        #"{"list":"","# + s + #","defaultStore":"a"}"#,
        #"{"list":"L","stores":[],"defaultStore":"a"}"#,
        #"{"list":"L","stores":[{"id":"","name":"A"}],"defaultStore":""}"#,
        #"{"list":"L","stores":[{"id":"a","name":"A"},{"id":"a","name":"B"}],"defaultStore":"a"}"#,
        #"{"list":"L","# + s + #","defaultStore":"z"}"#,
        #"{"list":"L","# + s + #","defaultStore":"a","storeKeywords":{"z":["x"]}}"#,
        #"{"list":"L","# + s + #","defaultStore":"a","categories":{"Gadgets":["x"]}}"#,
        #"{"list":"L","# + s + #","defaultStore":"a","categories":{"Other":["x"]}}"#,
        #"{"list":"L","# + s + #","defaultStore":"a","categories":{"Produce":[""]}}"#,
    ] {
        #expect(throws: ConfigError.self) { try Config.decode(withShopping(bad)) }
    }
}

private func withPhotos(_ photos: String) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"photos\":\(photos)}".utf8)
}

@Test func photosIsOptionalAndParses() throws {
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).photos == nil)
    #expect(try Config.decode(withPhotos(#"{"album":"Frame"}"#)).photos == PhotosConfig(album: "Frame"))
}

@Test func photosRejectsEmptyAlbum() {
    #expect(throws: ConfigError.badPhotos("\"photos.album\" is empty")) { try Config.decode(withPhotos(#"{"album":""}"#)) }
}

private func hueJSON(_ hue: String) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"hue\":\(hue)}".utf8)
}

@Test func configHueIsOptionalAndDefaultsIcons() throws {
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).hue == nil)
    #expect(try Config.decode(hueJSON(#"{"bridge":"bridge.invalid"}"#)).hue == HueConfig(bridge: "bridge.invalid", sceneIcons: [:]))
    #expect(try Config.decode(hueJSON(#"{"bridge":"bridge.invalid","sceneIcons":{"Dinner":"utensils"}}"#)).hue?.sceneIcons == ["Dinner": "utensils"])
}

@Test func configRejectsBadHue() {
    let bad = [
        #"{"bridge":""}"#, #"{"bridge":"https://bridge.invalid"}"#, #"{"bridge":"bridge.invalid/x"}"#, #"{"bridge":"a b"}"#,
        #"{"bridge":"bridge.invalid","sceneIcons":{"":"utensils"}}"#, #"{"bridge":"bridge.invalid","sceneIcons":{"Dinner":""}}"#,
    ]
    for hue in bad {
        #expect(throws: ConfigError.self) { try Config.decode(hueJSON(hue)) }
    }
}
