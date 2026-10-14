import Hummingbird

/// `Room` in the contract: a Hue room or zone.
public struct Room: ResponseEncodable, Decodable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case room, zone }

    public var id: String
    public var name: String
    public var kind: Kind
    public var on: Bool
    public var level: Int
    public var lights: [String]

    public init(id: String, name: String, kind: Kind, on: Bool, level: Int, lights: [String]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.on = on
        self.level = level
        self.lights = lights
    }
}
