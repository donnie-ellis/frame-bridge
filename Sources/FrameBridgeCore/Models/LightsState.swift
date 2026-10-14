import Hummingbird

/// `LightsState` in the contract.
public struct LightsState: ResponseEncodable, Decodable, Equatable, Sendable {
    public var rooms: [Room]
    public var devices: [Light]
    public var scenes: [Scene]

    public init(rooms: [Room], devices: [Light], scenes: [Scene]) {
        self.rooms = rooms
        self.devices = devices
        self.scenes = scenes
    }
}
