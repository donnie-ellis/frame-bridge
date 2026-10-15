import Foundation
import Testing

@testable import FrameBridgeCore

private func messages(_ text: String, chunk: Int? = nil) -> [String] {
    var parser = HueEventStreamParser()
    let bytes = Data(text.utf8)
    guard let chunk else { return parser.feed(bytes) }
    var out: [String] = []
    var i = 0
    while i < bytes.count {
        out += parser.feed(bytes[i..<min(i + chunk, bytes.count)])
        i += chunk
    }
    return out
}

private func state(_ r: HueResources) -> LightsState { LightsMapping.state(r, sceneIcons: HueFixture.icons) }

/// Applies every message of a fixture to the fixture snapshot.
private func merged(_ fixture: String, into start: HueResources? = nil) throws -> (resources: HueResources, needsResync: Bool) {
    var r = try start ?? HueFixture.resources()
    var resync = false
    for message in messages(try HueFixture.text(fixture)) {
        if HueEventMerge.apply(HueEventDecoder.batches(in: message), to: &r) { resync = true }
    }
    return (r, resync)
}

// MARK: parser

@Test func parserSplitsMessagesAndIgnoresCommentsAndIds() throws {
    let all = messages(try HueFixture.text("light-update"))
    #expect(all.count == 3)
    #expect(all.allSatisfy { $0.hasPrefix("[{") && !$0.contains("id: ") })
    #expect(all[2].contains("\n"))
    #expect(HueEventDecoder.batches(in: all[2]).first?.resources.first?.id == HueFixture.grouped(1))
}

@Test func parserGivesTheSameMessagesWholeByteByByteAndWithCRLF() throws {
    let text = try HueFixture.text("light-update")
    let whole = messages(text)
    #expect(messages(text, chunk: 1) == whole)
    #expect(messages(text, chunk: 7) == whole)
    #expect(messages(text.replacingOccurrences(of: "\n", with: "\r\n"), chunk: 1) == whole)
}

@Test func parserHoldsAMessageUntilTheBlankLine() {
    var parser = HueEventStreamParser()
    #expect(parser.feed(Data("data: [1]\n".utf8)).isEmpty)
    #expect(parser.feed(Data("\n".utf8)) == ["[1]"])
}

@Test func decoderSkipsUnknownShapes() throws {
    let all = messages(try HueFixture.text("unrelated"))
    #expect(all.count == 4)
    #expect(HueEventDecoder.batches(in: all[2]).count == 1) // the one object with a type and data
    #expect(HueEventDecoder.batches(in: all[3]).isEmpty)
}

// MARK: merge

@Test func lightOffKeepsItsLevel() throws {
    let (r, resync) = try merged("light-update")
    #expect(!resync)
    let light = try #require(state(r).devices.first { $0.id == HueFixture.light(1) })
    #expect(!light.on && light.level == 80)
}

@Test func brightnessIsRounded() throws {
    let (r, _) = try merged("light-update")
    #expect(state(r).devices.first { $0.id == HueFixture.light(3) }?.level == 43)
}

@Test func groupedLightChangesTheRoom() throws {
    let (r, _) = try merged("light-update")
    let room = try #require(state(r).rooms.first { $0.id == HueFixture.roomA })
    #expect(!room.on && room.level == 80)
}

@Test func sceneRecallSwitchesTheActiveScene() throws {
    let before = state(try HueFixture.resources())
    let (r, resync) = try merged("scene-recall")
    #expect(!resync)
    let after = state(r)
    #expect(before.scenes.first { $0.id == HueFixture.scene(1) }?.active == true)
    #expect(after.scenes.first { $0.id == HueFixture.scene(1) }?.active == false)
    #expect(after.scenes.first { $0.id == HueFixture.scene(3) }?.active == true)
    let events = HueEventMerge.events(from: before, to: after)
    #expect(events.map(\.name) == ["light", "room", "scene", "scene"])
}

@Test func structuralEventsNeedAResync() throws {
    let start = try HueFixture.resources()
    for (index, message) in messages(try HueFixture.text("structural")).enumerated() {
        var r = start
        #expect(HueEventMerge.apply(HueEventDecoder.batches(in: message), to: &r), "message \(index)")
    }
}

@Test func anUpdateToAnUnknownIDNeedsAResync() {
    var r = HueResources()
    let batch = HueEventBatch(kind: .update, resources: [HueEventResource(id: "x", type: "light", on: true)])
    #expect(HueEventMerge.apply([batch], to: &r))
}

@Test func repeatedOwnerOrGroupIsNotStructural() throws {
    var r = try HueFixture.resources()
    let owner = try #require(r.lights.first { $0.id == HueFixture.light(1) }?.owner)
    let group = try #require(r.scenes.first { $0.id == HueFixture.scene(1) }?.group)
    let batch = HueEventBatch(kind: .update, resources: [
        HueEventResource(id: HueFixture.light(1), type: "light", owner: owner),
        HueEventResource(id: HueFixture.scene(1), type: "scene", group: group),
    ])
    #expect(!HueEventMerge.apply([batch], to: &r))
}

@Test func unrelatedTypesChangeNothing() throws {
    let start = try HueFixture.resources()
    let (r, resync) = try merged("unrelated")
    #expect(!resync)
    #expect(r == start)
    #expect(HueEventMerge.events(from: state(start), to: state(r)).isEmpty)
}

@Test func anIdenticalUpdateSendsNoEvents() throws {
    let (once, _) = try merged("light-update")
    let (twice, _) = try merged("light-update", into: once)
    #expect(HueEventMerge.events(from: state(once), to: state(twice)).isEmpty)
}

@Test func aSceneKeepsItsConfigIcon() throws {
    let start = try HueFixture.resources()
    var r = start
    let batch = HueEventBatch(kind: .update, resources: [HueEventResource(id: HueFixture.scene(6), type: "scene", active: "static")])
    #expect(!HueEventMerge.apply([batch], to: &r))
    let events = HueEventMerge.events(from: state(start), to: state(r))
    guard case .scene(let scene) = try #require(events.first) else { Issue.record("not a scene event"); return }
    #expect(scene.active && scene.icon == "utensils")
    #expect(try events[0].encoded().contains(#""icon":"utensils""#))
}

// MARK: ids changed

@Test func idsChangedForAddsAndRemoves() throws {
    let base = try HueFixture.resources()
    var withoutScene = base
    withoutScene.scenes.removeAll { $0.id == HueFixture.scene(4) }
    #expect(HueEventMerge.idsChanged(state(base), state(withoutScene)))
    var withoutLight = base
    for i in withoutLight.rooms.indices { withoutLight.rooms[i].children.removeAll { $0.rid == "7e3c8d22-0000-4000-8000-000000000002" } }
    #expect(HueEventMerge.idsChanged(state(base), state(withoutLight)))
    #expect(!HueEventMerge.idsChanged(state(base), state(base)))
}

@Test func renameAndRoomMoveKeepTheIDs() throws {
    let base = try HueFixture.resources()
    var renamed = base
    renamed.lights[0].metadata = HueMetadata(name: "Other")
    #expect(!HueEventMerge.idsChanged(state(base), state(renamed)))

    var moved = base
    let device = HueRef(rid: "7e3c8d22-0000-4000-8000-000000000002", rtype: "device")
    moved.rooms[0].children.removeAll { $0 == device }
    moved.rooms[1].children.append(device)
    #expect(!HueEventMerge.idsChanged(state(base), state(moved)))
    let names = HueEventMerge.events(from: state(base), to: state(moved)).map(\.name)
    #expect(names.contains("light") && names.contains("room"))
}

// MARK: colour and white temperature

@Test func switchingToColourModeAndBackFollowsTheStream() throws {
    let start = try HueFixture.resources()
    let before = try #require(state(start).devices.first { $0.id == HueFixture.light(1) })
    #expect(before.temp == 2703)
    let all = messages(try HueFixture.text("color-update"))
    #expect(all.count == 2)

    var r = start
    #expect(!HueEventMerge.apply(HueEventDecoder.batches(in: all[0]), to: &r))
    let colour = try #require(state(r).devices.first { $0.id == HueFixture.light(1) })
    #expect(colour.temp == nil && colour.color != before.color && colour.tempRange == before.tempRange)
    #expect(HueEventMerge.events(from: state(start), to: state(r)).map(\.name) == ["light"])
    #expect(r.lights[0].color?.gamut != nil && r.lights[0].colorTemperature?.mirek == nil)

    #expect(!HueEventMerge.apply(HueEventDecoder.batches(in: all[1]), to: &r))
    let white = try #require(state(r).devices.first { $0.id == HueFixture.light(1) })
    #expect(white.temp == 4000 && white.color == colour.color)
}

@Test func colourFieldsOnALightWithoutThemAreIgnored() {
    let batch = HueEventDecoder.batches(in: #"[{"type":"update","data":[{"id":"x","type":"light","color_temperature":{"mirek":null,"mirek_valid":false}}]}]"#)
    #expect(batch.first?.resources.first?.mirek == nil)
    #expect(batch.first?.resources.first?.mirekValid == false)
}
