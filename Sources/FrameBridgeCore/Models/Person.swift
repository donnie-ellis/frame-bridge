/// One family member. Optional `night` is omitted when nil.
public struct Person: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let color: String
    public let night: String?

    public init(id: String, name: String, color: String, night: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.night = night
    }
}
