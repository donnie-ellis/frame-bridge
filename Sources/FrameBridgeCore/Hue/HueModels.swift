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
    struct ColorTemperature: Decodable, Equatable, Sendable {
        struct Schema: Decodable, Equatable, Sendable {
            let mirekMinimum: Int
            let mirekMaximum: Int
            enum CodingKeys: String, CodingKey { case mirekMinimum = "mirek_minimum", mirekMaximum = "mirek_maximum" }
        }
        /// `null` in colour mode.
        var mirek: Int?
        var mirekValid: Bool
        let mirekSchema: Schema
        enum CodingKeys: String, CodingKey { case mirek, mirekValid = "mirek_valid", mirekSchema = "mirek_schema" }
    }
    struct XY: Decodable, Equatable, Sendable { let x: Double; let y: Double }
    struct Color: Decodable, Equatable, Sendable {
        struct Gamut: Decodable, Equatable, Sendable { let red: XY; let green: XY; let blue: XY }
        var xy: XY
        let gamut: Gamut?
    }
    let id: String
    let owner: HueRef
    var metadata: HueMetadata
    var on: On
    var dimming: Dimming?
    var colorTemperature: ColorTemperature?
    var color: Color?
    enum CodingKeys: String, CodingKey { case id, owner, metadata, on, dimming, colorTemperature = "color_temperature", color }
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
