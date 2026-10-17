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

private func withCalendar(_ calendar: String, people: String = ##"[{"id":"a","name":"A","color":"#112233"},{"id":"b","name":"B","color":"#445566"}]"##) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"people\":\(people),\"calendar\":\(calendar)}".utf8)
}

private func withPeople(_ people: String) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"people\":\(people)}".utf8)
}

@Test func peopleKeepOrderAndOptionalNight() throws {
    let c = try Config.decode(withPeople(##"[{"id":"z","name":"Z","color":"#112233","night":"#aabbcc"},{"id":"a","name":"A","color":"#445566"}]"##))
    #expect(c.people?.map(\.id) == ["z", "a"])
    #expect(c.people?[0].night == "#aabbcc")
    #expect(c.people?[1].night == nil)
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).people == nil)
}

@Test func peopleAcceptsFamilyId() throws {
    #expect(try Config.decode(withPeople(##"[{"id":"family","name":"F","color":"#112233"}]"##)).people?.count == 1)
}

@Test func peopleRejectsBadEntries() {
    for bad in [
        ##"[{"id":"a","name":"A","color":"#112233"},{"id":"a","name":"B","color":"#112233"}]"##,
        ##"[{"id":"","name":"A","color":"#112233"}]"##,
        ##"[{"id":"a","name":"","color":"#112233"}]"##,
        ##"[{"id":"a","name":"A","color":"#2D5BFF"}]"##,
        ##"[{"id":"a","name":"A","color":"#abc"}]"##,
        ##"[{"id":"a","name":"A","color":"2d5bff"}]"##,
        ##"[{"id":"a","name":"A","color":"#112233","night":"#GGGGGG"}]"##,
    ] {
        do {
            _ = try Config.decode(withPeople(bad))
            Issue.record("accepted \(bad)")
        } catch let error as ConfigError {
            guard case .badPeople = error else { Issue.record("wrong error \(error)"); continue }
        } catch { Issue.record("wrong error \(error)") }
    }
}

@Test func calendarIsOptionalAndParses() throws {
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).calendar == nil)
    let c = try Config.decode(withCalendar("{\"calendars\":{\"Family\":\"all\",\"Mine\":[\"a\"]}}"))
    #expect(c.calendar?.people(for: "Family") == ["a", "b"])
    #expect(c.calendar?.people(for: "Mine") == ["a"])
    #expect(c.calendar?.people(for: "Other") == nil)
}

@Test func calendarRejectsBadSections() {
    for bad in [
        "{\"calendars\":{\"X\":[]}}",
        "{\"calendars\":{\"X\":[\"zed\"]}}",
        "{\"calendars\":{\"X\":\"everyone\"}}",
        "{\"people\":[\"a\"],\"calendars\":{}}",
    ] {
        #expect(throws: ConfigError.self) { try Config.decode(withCalendar(bad)) }
    }
}

@Test func calendarWithoutPeopleIsRejected() {
    #expect(throws: ConfigError.self) { try Config.decode(withCalendar("{\"calendars\":{}}", people: "[]")) }
    let data = Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"calendar\":{\"calendars\":{}}}".utf8)
    #expect(throws: ConfigError.self) { try Config.decode(data) }
}

@Test func leftoverCalendarPeopleSaysItMoved() {
    do {
        _ = try Config.decode(withCalendar("{\"people\":[\"a\"],\"calendars\":{}}"))
        Issue.record("accepted")
    } catch { #expect(String(describing: error).contains("moved to the top-level people section")) }
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

private func sonosJSON(_ sonos: String) -> Data {
    Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"sonos\":\(sonos)}".utf8)
}

@Test func configSonosIsOptional() throws {
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).sonos == nil)
    #expect(try Config.decode(sonosJSON(#"{"host":"192.0.2.10","room":"Room A"}"#)).sonos == SonosConfig(host: "192.0.2.10", room: "Room A"))
}

@Test func configRejectsBadSonos() {
    let bad = [#"{"host":"192.0.2.10","room":""}"#, #"{"host":"","room":"Room A"}"#, #"{"host":"http://192.0.2.10","room":"Room A"}"#,
               #"{"host":"192.0.2.10/x","room":"Room A"}"#, #"{"host":"192.0.2.10:1400","room":"Room A"}"#, #"{"host":"a b","room":"Room A"}"#]
    for sonos in bad {
        #expect(throws: ConfigError.self) { try Config.decode(sonosJSON(sonos)) }
    }
}

private func choresPeople(_ a: String?, _ b: String?) -> Data {
    func entry(_ id: String, _ list: String?) -> String {
        let chores = list.map { ",\"chores\":\"\($0)\"" } ?? ""
        return "{\"id\":\"\(id)\",\"name\":\"N\",\"color\":\"#112233\"\(chores)}"
    }
    return Data("{\"frames\":{\"kitchen\":\"\(good)\"},\"dashboardDir\":\"/tmp/dist\",\"people\":[\(entry("a", a)),\(entry("b", b))],\"shopping\":{\"list\":\"Shop\",\"stores\":[{\"id\":\"s\",\"name\":\"S\"}],\"defaultStore\":\"s\"}}".utf8)
}

@Test func choresListsComeFromPeopleInOrder() throws {
    let c = try Config.decode(choresPeople("L1", "L2"))
    #expect(c.chores?.lists == [ChoreListRef(person: "a", list: "L1"), ChoreListRef(person: "b", list: "L2")])
    #expect(try Config.decode(choresPeople(nil, "L2")).chores?.lists == [ChoreListRef(person: "b", list: "L2")])
    #expect(try Config.decode(choresPeople(nil, nil)).chores == nil)
    #expect(try Config.decode(json("{\"kitchen\":\"\(good)\"}")).chores == nil)
}

@Test func choresRejectsEmptyDuplicateAndShoppingList() {
    #expect(throws: ConfigError.badChores("person \"a\" has an empty chore list name")) { try Config.decode(choresPeople("", nil)) }
    #expect(throws: ConfigError.badChores("people \"a\" and \"b\" share a chore list")) { try Config.decode(choresPeople("L", "L")) }
    #expect(throws: ConfigError.badChores("person \"b\" has the shopping list as a chore list")) { try Config.decode(choresPeople("L", "Shop")) }
}

@Test func peopleRouteHasNoChoresKey() async throws {
    let c = try Config.decode(choresPeople("L1", nil))
    let people = try #require(c.people)
    #expect(!String(decoding: try JSONEncoder().encode(people), as: UTF8.self).contains("chores"))
}
