import Foundation

/// Hue CLIP v2 JSON, only the fields frame-bridge reads. The bridge's `errors` array is ignored.
struct HueEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let data: [T]
}

struct HueRef: Decodable, Equatable, Sendable {
    let rid: String
    let rtype: String
}

struct HueMetadata: Decodable, Equatable, Sendable {
    let name: String
}

struct HueLight: Decodable, Equatable, Sendable {
    struct On: Decodable, Equatable, Sendable { let on: Bool }
    struct Dimming: Decodable, Equatable, Sendable { let brightness: Double }
    let id: String
    let owner: HueRef
    var metadata: HueMetadata
    var on: On
    var dimming: Dimming?
}

struct HueDevice: Decodable, Equatable, Sendable {
    let id: String
    let services: [HueRef]
}

/// A room or a zone.
struct HueGroup: Decodable, Equatable, Sendable {
    let id: String
    var metadata: HueMetadata
    var children: [HueRef]
    let services: [HueRef]
}

struct HueGroupedLight: Decodable, Equatable, Sendable {
    let id: String
    var on: HueLight.On?
    var dimming: HueLight.Dimming?
}

struct HueScene: Decodable, Equatable, Sendable {
    struct Status: Decodable, Equatable, Sendable { let active: String }
    let id: String
    var metadata: HueMetadata
    let group: HueRef
    var status: Status?
}

/// One snapshot of everything the mapping needs.
struct HueResources: Equatable, Sendable {
    var lights: [HueLight] = []
    var devices: [HueDevice] = []
    var rooms: [HueGroup] = []
    var zones: [HueGroup] = []
    var groupedLights: [HueGroupedLight] = []
    var scenes: [HueScene] = []
}
