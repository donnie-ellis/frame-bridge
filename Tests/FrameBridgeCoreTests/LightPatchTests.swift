import Foundation
import Testing

@testable import FrameBridgeCore

@Test(arguments: [
    (#"{"on":true}"#, LightPatch(on: true)),
    (#"{"level":1}"#, LightPatch(level: 1)),
    (#"{"level":100}"#, LightPatch(level: 100)),
    (#"{"on":false,"level":50}"#, LightPatch(on: false, level: 50)),
])
func lightPatchAcceptsValid(json: String, expected: LightPatch) throws {
    #expect(try LightPatch.parse(Data(json.utf8)) == expected)
}

@Test(arguments: [
    "", "{}", "[]", "nope", #"{"extra":1}"#, #"{"on":null}"#, #"{"on":1}"#, #"{"on":"true"}"#,
    #"{"level":true}"#, #"{"level":60.5}"#, #"{"level":"60"}"#, #"{"level":0}"#, #"{"level":101}"#,
    #"{"level":null}"#, #"{"on":true,"extra":1}"#,
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
