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
    public var temp: Int?
    public var tempRange: TempRange?
    public var color: String?

    public struct TempRange: Codable, Equatable, Sendable {
        public var min: Int
        public var max: Int

        public init(min: Int, max: Int) {
            self.min = min
            self.max = max
        }
    }

    public init(id: String, room: String, name: String, on: Bool, level: Int,
                temp: Int? = nil, tempRange: TempRange? = nil, color: String? = nil) {
        self.id = id
        self.room = room
        self.name = name
        self.on = on
        self.level = level
        self.temp = temp
        self.tempRange = tempRange
        self.color = color
    }
}
