import Foundation
import Testing

@testable import FrameBridgeCore

private func state() throws -> LightsState {
    LightsMapping.state(try HueFixture.resources(), sceneIcons: HueFixture.icons)
}

@Test func levelRoundsClampsAndDefaults() {
    #expect(LightsMapping.level(nil) == 100)
    #expect(LightsMapping.level(0.4) == 1)
    #expect(LightsMapping.level(0) == 1)
    #expect(LightsMapping.level(79.6) == 80)
    #expect(LightsMapping.level(100) == 100)
}

@Test func lightsInNoRoomAreLeftOut() throws {
    let ids = try state().devices.map(\.id)
    #expect(ids == [HueFixture.light(1), HueFixture.light(2), HueFixture.light(3), HueFixture.light(4)])
}

@Test func lightRoomComesThroughItsDevice() throws {
    let s = try state()
    #expect(s.devices.map(\.room) == [HueFixture.roomA, HueFixture.roomA, HueFixture.roomB, HueFixture.roomB])
}

@Test func offLightKeepsItsLevelAndNoDimmingReports100() throws {
    let s = try state()
    let two = try #require(s.devices.first { $0.id == HueFixture.light(2) })
    #expect(!two.on && two.level == 50)
    #expect(s.devices.first { $0.id == HueFixture.light(1) }?.level == 80)
    #expect(s.devices.first { $0.id == HueFixture.light(3) }?.level == 1)
    #expect(s.devices.first { $0.id == HueFixture.light(4) }?.level == 100)
}

@Test func roomsComeFromGroupedLightAndKeepOrder() throws {
    let s = try state()
    #expect(s.rooms.map(\.id) == [HueFixture.roomA, HueFixture.roomB, HueFixture.zone])
    #expect(s.rooms.map(\.kind) == [.room, .room, .zone])
    #expect(s.rooms[0].on && s.rooms[0].level == 80)
    #expect(!s.rooms[1].on && s.rooms[1].level == 1)
    #expect(s.rooms[0].lights == [HueFixture.light(1), HueFixture.light(2)])
}

@Test func zoneListsItsLightsExceptTheRoomlessOne() throws {
    let zone = try #require(try state().rooms.last)
    #expect(zone.lights == [HueFixture.light(1), HueFixture.light(3)])
}

@Test func roomWithoutGroupedLightIsDroppedWithItsLightsAndScenes() throws {
    let s = try state()
    #expect(!s.rooms.contains { $0.id == HueFixture.roomC })
    #expect(!s.devices.contains { $0.id == HueFixture.light(6) })
    #expect(!s.scenes.contains { $0.room == HueFixture.roomC })
    #expect(s.scenes.count == 5)
}

@Test func sceneActiveUnlessInactiveOrMissingStatus() throws {
    let active = Dictionary(uniqueKeysWithValues: try state().scenes.map { ($0.id, $0.active) })
    #expect(active[HueFixture.scene(1)] == true)
    #expect(active[HueFixture.scene(2)] == true)
    #expect(active[HueFixture.scene(3)] == false)
    #expect(active[HueFixture.scene(4)] == false)
}

@Test func sceneInAZoneKeepsTheZoneAsRoom() throws {
    #expect(try state().scenes.last?.room == HueFixture.zone)
}

@Test func mappedSceneNameGetsAnIconAndTheEncodedJSONOmitsTheRest() throws {
    let s = try state()
    #expect(s.scenes[0].icon == "utensils")
    #expect(s.scenes[1].icon == nil)
    let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
    #expect(!json.contains("null"))
    let bright = String(decoding: try JSONEncoder().encode(s.scenes[1]), as: UTF8.self)
    #expect(!bright.contains("icon"))
}

private func hueLight(_ n: Int) throws -> HueLight {
    try #require(HueFixture.resources().lights.first { $0.id == HueFixture.light(n) })
}

private func body(_ patch: LightPatch, light n: Int = 2) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: LightsMapping.hueBody(for: patch, light: hueLight(n))) as? [String: Any])
}

@Test func hueBodyShapes() throws {
    let off = try body(LightPatch(on: false))
    #expect((off["on"] as? [String: Bool]) == ["on": false])
    #expect(off["dimming"] == nil)

    let level = try body(LightPatch(level: 60))
    #expect((level["on"] as? [String: Bool]) == ["on": true])
    #expect(((level["dimming"] as? [String: Int]) ?? [:]) == ["brightness": 60])

    let plain = try body(LightPatch(level: 60), light: 4)
    #expect((plain["on"] as? [String: Bool]) == ["on": true])
    #expect(plain["dimming"] == nil)

    let both = try body(LightPatch(on: true, level: 60))
    #expect((both["on"] as? [String: Bool]) == ["on": true])
    #expect(((both["dimming"] as? [String: Int]) ?? [:]) == ["brightness": 60])
}

@Test func groupedLightIDForRoomsAndZones() throws {
    let r = try HueFixture.resources()
    #expect(LightsMapping.groupedLightID(ofGroup: HueFixture.roomA, in: r) == HueFixture.grouped(1))
    #expect(LightsMapping.groupedLightID(ofGroup: HueFixture.roomB, in: r) == HueFixture.grouped(2))
    #expect(LightsMapping.groupedLightID(ofGroup: HueFixture.zone, in: r) == HueFixture.grouped(3))
    #expect(LightsMapping.groupedLightID(ofGroup: HueFixture.roomC, in: r) == nil)
    #expect(LightsMapping.groupedLightID(ofGroup: "nope", in: r) == nil)
}

@Test func roomAfterTakesOnAndLevelFromTheGroupedLight() throws {
    let base = Room(id: "r", name: "N", kind: .zone, on: true, level: 10, lights: ["a"])
    func grouped(_ json: String) throws -> HueGroupedLight { try JSONDecoder().decode(HueGroupedLight.self, from: Data(json.utf8)) }
    let off = LightsMapping.room(base, after: try grouped(#"{"id":"g","on":{"on":false},"dimming":{"brightness":0.4}}"#))
    #expect(off == Room(id: "r", name: "N", kind: .zone, on: false, level: 1, lights: ["a"]))
    let plain = LightsMapping.room(base, after: try grouped(#"{"id":"g","on":{"on":true}}"#))
    #expect(plain.on && plain.level == 100)
}

@Test func recallBodyIsTheSpecBody() throws {
    let object = try #require(JSONSerialization.jsonObject(with: LightsMapping.recallBody) as? [String: [String: String]])
    #expect(object == ["recall": ["action": "active"]])
}

@Test func lightsGetTempRangeAndColorOnlyWhereTheyApply() throws {
    let s = try state()
    let one = try #require(s.devices.first { $0.id == HueFixture.light(1) })
    #expect(one.temp == 2703 && one.tempRange == Light.TempRange(min: 2000, max: 6536))
    #expect(one.color?.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil)
    // Colour mode and off: no temp, still tempRange and color.
    let two = try #require(s.devices.first { $0.id == HueFixture.light(2) })
    #expect(two.temp == nil && two.tempRange != nil && two.color != nil && !two.on)
    // A light with neither capability has none of the new fields, and no null.
    let four = try #require(s.devices.first { $0.id == HueFixture.light(4) })
    #expect(four.temp == nil && four.tempRange == nil && four.color == nil)
    let json = String(decoding: try JSONEncoder().encode(four), as: UTF8.self)
    #expect(!json.contains("temp") && !json.contains("color") && !json.contains("null"))
    let jsonTwo = String(decoding: try JSONEncoder().encode(two), as: UTF8.self)
    #expect(!jsonTwo.contains("\"temp\"") && !jsonTwo.contains("null"))
}

@Test func whiteAmbianceLightHasTempButNoColor() throws {
    var l = try hueLight(3)
    l.colorTemperature = HueLight.ColorTemperature(mirek: 250, mirekValid: true, mirekSchema: .init(mirekMinimum: 153, mirekMaximum: 454))
    let mapped = LightsMapping.light(l, room: "r")
    #expect(mapped.temp == 4000 && mapped.tempRange == Light.TempRange(min: 2203, max: 6536) && mapped.color == nil)
}

@Test func hueBodyForTempAndColor() throws {
    let temp = try body(LightPatch(temp: 2700))
    #expect((temp["on"] as? [String: Bool]) == ["on": true])
    #expect((temp["color_temperature"] as? [String: Int]) == ["mirek": 370])
    #expect(temp["color"] == nil)
    // Clamped to the light's range.
    #expect((try body(LightPatch(temp: 10000))["color_temperature"] as? [String: Int]) == ["mirek": 153])

    let colored = try body(LightPatch(on: true, color: "#ff8a3d"))
    let xy = try #require((colored["color"] as? [String: Any])?["xy"] as? [String: Double])
    #expect(xy.count == 2 && colored["color_temperature"] == nil)
    let off = try body(LightPatch(on: false, temp: 2700))
    #expect((off["on"] as? [String: Bool]) == ["on": false])
}

@Test func hueBodyRejectsWhatTheLightCannotDo() throws {
    let plain = try hueLight(4)
    for patch in [LightPatch(temp: 2700), LightPatch(color: "#ff8a3d")] {
        do {
            _ = try LightsMapping.hueBody(for: patch, light: plain)
            Issue.record("expected 400")
        } catch {
            #expect(error.error == "bad_request")
        }
    }
}
