import Foundation

/// Startup config, read once from a JSON file outside the repo.
public struct Config: Decodable, Sendable {
    /// Frame name -> lowercase hex SHA-256 of that frame's token.
    public let frames: [String: String]

    /// Absolute path of the built dashboard that is served at `/`.
    public let dashboardDir: String

    /// Home location and unit for the forecast. Absent: the weather feed reports "not configured".
    public let weather: WeatherConfig?

    /// Calendars to read and who they are for. Absent: the calendar feed reports "not configured".
    public let calendar: CalendarConfig?

    public init(frames: [String: String], dashboardDir: String, weather: WeatherConfig? = nil, calendar: CalendarConfig? = nil) {
        self.frames = frames
        self.dashboardDir = dashboardDir
        self.weather = weather
        self.calendar = calendar
    }

    public static func decode(_ data: Data) throws -> Config {
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.malformed(String(describing: error))
        }
        if config.frames.isEmpty { throw ConfigError.noFrames }
        for (name, hash) in config.frames.sorted(by: { $0.key < $1.key }) {
            if name.isEmpty { throw ConfigError.badHash(frame: "(empty name)") }
            if !isValidHash(hash) { throw ConfigError.badHash(frame: name) }
        }
        if !config.dashboardDir.hasPrefix("/") { throw ConfigError.badDashboardDir }
        if let w = config.weather {
            if !(-90...90).contains(w.latitude) { throw ConfigError.badWeather(field: "latitude") }
            if !(-180...180).contains(w.longitude) { throw ConfigError.badWeather(field: "longitude") }
        }
        if let c = config.calendar { try c.validate() }
        return config
    }

    public static func load(from url: URL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(url.path)
        }
        return try decode(data)
    }

    public static func defaultPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("frame-bridge").appendingPathComponent("config.json")
    }

    private static func isValidHash(_ hash: String) -> Bool {
        let bytes = Array(hash.utf8)
        return bytes.count == 64 && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// The home coordinates are private: never log or print them.
public struct WeatherConfig: Decodable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let unit: TemperatureUnit

    public init(latitude: Double, longitude: Double, unit: TemperatureUnit) {
        self.latitude = latitude
        self.longitude = longitude
        self.unit = unit
    }
}

/// Calendar title -> person ids. Titles are private: never log them above debug.
public struct CalendarConfig: Decodable, Sendable, Equatable {
    public let people: [String]
    public let calendars: [String: CalendarPeople]

    public init(people: [String], calendars: [String: CalendarPeople]) {
        self.people = people
        self.calendars = calendars
    }

    func validate() throws {
        if people.isEmpty { throw ConfigError.badCalendar("\"calendar.people\" must list at least one person") }
        if people.contains("") { throw ConfigError.badCalendar("\"calendar.people\" has an empty id") }
        if Set(people).count != people.count { throw ConfigError.badCalendar("\"calendar.people\" has a duplicate id") }
        for (_, value) in calendars {
            guard case .ids(let ids) = value else { continue }
            if ids.isEmpty { throw ConfigError.badCalendar("a calendar maps to no people") }
            if let unknown = ids.first(where: { !people.contains($0) }) {
                throw ConfigError.badCalendar("person \"\(unknown)\" is not in \"calendar.people\"")
            }
        }
    }

    /// Person ids for a calendar title, deduplicated, "all" in config order. Nil if not mapped.
    func people(for title: String) -> [String]? {
        switch calendars[title] {
        case nil: nil
        case .all: people
        case .ids(let ids): ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }
    }
}

/// `"all"` or a list of person ids.
public enum CalendarPeople: Decodable, Sendable, Equatable {
    case all
    case ids([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) {
            guard text == "all" else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected \"all\" or a list of person ids")
            }
            self = .all
        } else {
            self = .ids(try c.decode([String].self))
        }
    }
}

public enum TemperatureUnit: String, Decodable, Sendable { case celsius, fahrenheit }

/// Messages name the frame, never the hash.
public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case malformed(String)
    case noFrames
    case badHash(frame: String)
    case badDashboardDir
    case badWeather(field: String)
    case badCalendar(String)

    public var description: String {
        switch self {
        case .unreadable(let path): "cannot read file at \(path)"
        case .malformed(let detail): "malformed JSON: \(detail)"
        case .noFrames: "\"frames\" must list at least one frame"
        case .badDashboardDir: "\"dashboardDir\" must be an absolute path"
        case .badWeather(let field): "\"weather.\(field)\" is out of range"
        case .badCalendar(let detail): "calendar config: \(detail)"
        case .badHash(let frame): "frame \"\(frame)\" needs a 64-character lowercase hex SHA-256 hash"
        }
    }
}
