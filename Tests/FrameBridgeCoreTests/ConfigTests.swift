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
