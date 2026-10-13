import Hummingbird

/// `Light` in the contract.
public struct Light: ResponseEncodable, Decodable, Equatable, Sendable {
    public var id: String
    public var room: String
    /// Always `light`.
    public var type = "light"
    public var name: String
    public var on: Bool
    public var level: Int

    public init(id: String, room: String, name: String, on: Bool, level: Int) {
        self.id = id
        self.room = room
        self.name = name
        self.on = on
        self.level = level
    }
}
