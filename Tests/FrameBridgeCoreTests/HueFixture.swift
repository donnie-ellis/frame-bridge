import Foundation
import Testing

@testable import FrameBridgeCore

/// Scrubbed Hue CLIP v2 snapshots: fake ids and names, no addresses.
enum HueFixture {
    static let roomA = "0f6c1a9e-0000-4000-8000-000000000001"
    static let roomB = "0f6c1a9e-0000-4000-8000-000000000002"
    static let roomC = "0f6c1a9e-0000-4000-8000-000000000003"
    static let zone = "1a7d2bf0-0000-4000-8000-000000000001"
    static func light(_ n: Int) -> String { "6d2b7c11-0000-4000-8000-" + String(format: "%012d", n) }
    static func scene(_ n: Int) -> String { "3a9d5e20-0000-4000-8000-" + String(format: "%012d", n) }
    static let icons = ["Dinner": "utensils"]

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/hue"))
        return try Data(contentsOf: url)
    }

    private static func list<T: Decodable & Sendable>(_ name: String, _ type: T.Type) throws -> [T] {
        try JSONDecoder().decode(HueEnvelope<T>.self, from: data(name)).data
    }

    static func resources() throws -> HueResources {
        HueResources(
            lights: try list("light", HueLight.self), devices: try list("device", HueDevice.self),
            rooms: try list("room", HueGroup.self), zones: try list("zone", HueGroup.self),
            groupedLights: try list("grouped_light", HueGroupedLight.self), scenes: try list("scene", HueScene.self)
        )
    }
}

/// Serves the fixtures by path and records every request. Light state is mutable so a PUT shows
/// up in the next GET.
actor FakeHueTransport: HueTransport {
    struct Request: Equatable { let method: String; let path: String; let body: Data? }
    private(set) var requests: [Request] = []
    private var lightOverride: [String: [String: Any]] = [:]
    var failure: (any Error)?
    var statusOverride: Int?

    func setFailure(_ error: (any Error)?) { failure = error }
    func setStatus(_ status: Int?) { statusOverride = status }

    func send(method: String, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        requests.append(Request(method: method, path: path, body: body))
        if let failure { throw failure }
        if let statusOverride { return (statusOverride, Data(#"{"errors":[],"data":[]}"#.utf8)) }
        if method == "PUT", path.hasPrefix("resource/light/") {
            let id = String(path.dropFirst("resource/light/".count))
            guard let patch = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any] else { return (400, Data()) }
            lightOverride[id, default: [:]].merge(patch) { _, new in new }
            return (200, Data(#"{"errors":[],"data":[]}"#.utf8))
        }
        guard method == "GET", path.hasPrefix("resource/") else { return (404, Data()) }
        let rest = String(path.dropFirst("resource/".count))
        if rest.hasPrefix("light/") {
            let id = String(rest.dropFirst("light/".count))
            let all = try JSONSerialization.jsonObject(with: HueFixture.data("light")) as? [String: Any]
            let match = (all?["data"] as? [[String: Any]])?.first { $0["id"] as? String == id }
            guard var found = match else { return (404, Data(#"{"errors":[{"description":"x"}],"data":[]}"#.utf8)) }
            apply(lightOverride[id], to: &found)
            return (200, try JSONSerialization.data(withJSONObject: ["errors": [], "data": [found]]))
        }
        if rest == "light" {
            let all = try JSONSerialization.jsonObject(with: HueFixture.data("light")) as? [String: Any]
            var items = (all?["data"] as? [[String: Any]]) ?? []
            for i in items.indices { apply(lightOverride[items[i]["id"] as? String ?? ""], to: &items[i]) }
            return (200, try JSONSerialization.data(withJSONObject: ["errors": [], "data": items]))
        }
        return (200, try HueFixture.data(rest))
    }

    private func apply(_ patch: [String: Any]?, to light: inout [String: Any]) {
        guard let patch else { return }
        if let on = patch["on"] { light["on"] = on }
        if let dimming = patch["dimming"] as? [String: Any], var current = light["dimming"] as? [String: Any] {
            current.merge(dimming) { _, new in new }
            light["dimming"] = current
        }
    }

    func recorded() -> [Request] { requests }
}
