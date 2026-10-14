import Hummingbird

/// `Scene` in the contract.
public struct Scene: ResponseEncodable, Decodable, Equatable, Sendable {
    public var id: String
    public var room: String
    public var name: String
    public var active: Bool
    /// Omitted when the scene name isn't in the config's icon map.
    public var icon: String?

    public init(id: String, room: String, name: String, active: Bool, icon: String? = nil) {
        self.id = id
        self.room = room
        self.name = name
        self.active = active
        self.icon = icon
    }
}
