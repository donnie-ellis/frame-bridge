import Foundation
import Testing

@testable import FrameBridgeCore

@Test(arguments: [
    (#"{"on":true}"#, LightPatch(on: true)),
    (#"{"level":1}"#, LightPatch(level: 1)),
    (#"{"level":100}"#, LightPatch(level: 100)),
    (#"{"on":false,"level":50}"#, LightPatch(on: false, level: 50)),
    (#"{"temp":2700}"#, LightPatch(temp: 2700)),
    (##"{"color":"#ff8a3d"}"##, LightPatch(color: "#ff8a3d")),
    (#"{"on":false,"temp":2700}"#, LightPatch(on: false, temp: 2700)),
    (##"{"level":60,"color":"#ff8a3d"}"##, LightPatch(level: 60, color: "#ff8a3d")),
])
func lightPatchAcceptsValid(json: String, expected: LightPatch) throws {
    #expect(try LightPatch.parse(Data(json.utf8)) == expected)
}

@Test(arguments: [
    "", "{}", "[]", "nope", #"{"extra":1}"#, #"{"on":null}"#, #"{"on":1}"#, #"{"on":"true"}"#,
    #"{"level":true}"#, #"{"level":60.5}"#, #"{"level":"60"}"#, #"{"level":0}"#, #"{"level":101}"#,
    #"{"level":null}"#, #"{"on":true,"extra":1}"#,
    ##"{"temp":2700,"color":"#ff8a3d"}"##, #"{"temp":2700.5}"#, #"{"temp":"2700"}"#, #"{"temp":true}"#, #"{"temp":null}"#,
    ##"{"color":"#FF8A3D"}"##, #"{"color":"ff8a3d"}"#, ##"{"color":"#fff"}"##, #"{"color":123}"#, ##"{"color":"#000000"}"##,
])
func lightPatchRejectsInvalid(json: String) {
    do {
        _ = try LightPatch.parse(Data(json.utf8))
        Issue.record("expected 400 for \(json)")
    } catch {
        #expect(error.error == "bad_request")
        #expect(error.status == .badRequest)
        #expect(error.detail != nil)
    }
}

@Test func roomPatchAcceptsOnAndLevel() throws {
    #expect(try RoomPatch.parse(Data(#"{"on":true}"#.utf8)) == RoomPatch(on: true))
    #expect(try RoomPatch.parse(Data(#"{"on":false,"level":50}"#.utf8)) == RoomPatch(on: false, level: 50))
}

@Test(arguments: [#"{"temp":2700}"#, ##"{"color":"#ff8a3d"}"##, "{}", #"{"extra":1}"#, #"{"level":0}"#])
func roomPatchRejectsInvalid(json: String) {
    do {
        _ = try RoomPatch.parse(Data(json.utf8))
        Issue.record("expected 400 for \(json)")
    } catch {
        #expect(error.status == .badRequest)
    }
}
