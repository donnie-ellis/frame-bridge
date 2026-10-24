import Foundation
import Testing

@testable import FrameBridgeCore

/// Scrubbed Sonos SOAP snapshots: documentation addresses, fake ids, placeholder names.
enum SonosFixture {
    static let hostA = "192.0.2.10"
    static let hostB = "192.0.2.20"

    static func data(_ name: String, ext: String = "xml") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/sonos"))
        return try Data(contentsOf: url)
    }
}

/// Serves the fixtures by action and records everything sent, so tests can check that only the
/// read-only actions went out.
actor StubSonosTransport: SonosTransport {
    private(set) var actions: [String] = []
    private(set) var gets: [String] = []
    private var topology: String
    private var transportState: String
    private var position: String
    private var unreachable = false
    private var artStatus = 200

    init(topology: String = "topology-alone", transport: String = "transport-playing", position: String = "position-music") {
        self.topology = topology
        self.transportState = transport
        self.position = position
    }

    func set(topology: String? = nil, transport: String? = nil, position: String? = nil, unreachable: Bool? = nil, artStatus: Int? = nil) {
        if let topology { self.topology = topology }
        if let transport { self.transportState = transport }
        if let position { self.position = position }
        if let unreachable { self.unreachable = unreachable }
        if let artStatus { self.artStatus = artStatus }
    }

    func soap(host: String, path: String, action: String, body: Data) async throws -> Data {
        actions.append(String(action.split(separator: "#").last ?? ""))
        if unreachable { throw SonosError.unreachable }
        switch action.split(separator: "#").last {
        case "GetZoneGroupState": return try SonosFixture.data(topology)
        case "GetTransportInfo": return try SonosFixture.data(transportState)
        case "GetPositionInfo": return try SonosFixture.data(position)
        default: throw SonosError.status(500)
        }
    }

    func get(host: String, path: String) async throws -> (status: Int, data: Data) {
        gets.append(path)
        if unreachable { throw SonosError.unreachable }
        return (artStatus, artStatus == 200 ? try SonosFixture.data("art", ext: "jpg") : Data())
    }
}

/// Records the art URLs asked for and serves the fixture image, or fails.
actor StubExternalArt: ExternalArtTransport {
    private(set) var urls: [URL] = []
    private var fail = false
    private var holding = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set(fail: Bool) { self.fail = fail }

    /// While holding, `get` records the URL and then waits for `release()`.
    func set(hold: Bool) { holding = hold }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func get(_ url: URL) async throws -> Data {
        urls.append(url)
        if holding, !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        if fail { throw ExternalArtError.unreachable }
        return try SonosFixture.data("art", ext: "jpg")
    }
}
