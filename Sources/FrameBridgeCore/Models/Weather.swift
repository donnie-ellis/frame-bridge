import Hummingbird

/// `Weather` in the contract.
public struct Weather: ResponseEncodable, Decodable, Equatable, Sendable {
    public var start: String
    public var hi: Int
    public var lo: Int
    public var t: [Int]
    public var c: [WeatherCondition]
    public var p: [Int]
}

public enum WeatherCondition: String, Codable, Sendable { case sun, moon, partly, cloud, rain, snow, storm }
