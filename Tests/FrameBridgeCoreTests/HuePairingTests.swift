import Foundation
import Testing

@testable import FrameBridgeCore

@Test func pairingSuccessGivesTheKey() {
    let data = Data(#"[{"success":{"username":"fake-key","clientkey":"fake"}}]"#.utf8)
    #expect(HuePairing.parseResponse(data) == .paired(key: "fake-key"))
}

@Test func pairingError101MeansLinkButton() {
    let data = Data(#"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#.utf8)
    #expect(HuePairing.parseResponse(data) == .linkButtonNotPressed)
}

@Test func pairingOtherErrorsAndGarbageFail() {
    if case .failed = HuePairing.parseResponse(Data(#"[{"error":{"type":7}}]"#.utf8)) {} else { Issue.record("expected failed") }
    if case .failed = HuePairing.parseResponse(Data("garbage".utf8)) {} else { Issue.record("expected failed") }
}

@Test func pairingRequestBody() throws {
    let object = try #require(JSONSerialization.jsonObject(with: HuePairing.pairingRequestBody()) as? [String: Any])
    #expect(object["devicetype"] as? String == "frame-bridge#macmini")
    #expect(object["generateclientkey"] as? Bool == true)
}
