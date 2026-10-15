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

    /// The Reminders list, stores and keyword maps. Absent: the shopping feed reports "not configured".
    public let shopping: ShoppingConfig?

    /// The shared album to show. Absent: the photos feed reports "not configured".
    public let photos: PhotosConfig?

    /// The Hue Bridge address and scene icons. Absent: the lights feed reports "not configured".
    public let hue: HueConfig?

    /// The Sonos speaker and room. Absent: the now playing routes answer 503 and `/healthz` omits `sonos`.
    public let sonos: SonosConfig?

    public init(frames: [String: String], dashboardDir: String, weather: WeatherConfig? = nil, calendar: CalendarConfig? = nil, shopping: ShoppingConfig? = nil, photos: PhotosConfig? = nil, hue: HueConfig? = nil, sonos: SonosConfig? = nil) {
        self.frames = frames
        self.dashboardDir = dashboardDir
        self.weather = weather
        self.calendar = calendar
        self.shopping = shopping
        self.photos = photos
        self.hue = hue
        self.sonos = sonos
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
        if let s = config.shopping { try s.validate() }
        if let p = config.photos { try p.validate() }
        if let h = config.hue { try h.validate() }
        if let s = config.sonos { try s.validate() }
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

/// The Reminders list to read and the keyword maps. List title and keywords are private: never log them.
public struct ShoppingConfig: Decodable, Sendable, Equatable {
    public let list: String
    public let stores: [Store]
    public let defaultStore: String
    /// Store id -> keywords.
    public let storeKeywords: [String: [String]]
    /// Category (a `ShoppingItem.Category` raw value) -> keywords.
    public let categories: [String: [String]]

    public init(list: String, stores: [Store], defaultStore: String, storeKeywords: [String: [String]] = [:], categories: [String: [String]] = [:]) {
        self.list = list
        self.stores = stores
        self.defaultStore = defaultStore
        self.storeKeywords = storeKeywords
        self.categories = categories
    }

    private enum CodingKeys: String, CodingKey { case list, stores, defaultStore, storeKeywords, categories }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        list = try c.decode(String.self, forKey: .list)
        stores = try c.decode([Store].self, forKey: .stores)
        defaultStore = try c.decode(String.self, forKey: .defaultStore)
        storeKeywords = try c.decodeIfPresent([String: [String]].self, forKey: .storeKeywords) ?? [:]
        categories = try c.decodeIfPresent([String: [String]].self, forKey: .categories) ?? [:]
    }

    func validate() throws {
        if list.isEmpty { throw ConfigError.badShopping("\"shopping.list\" is empty") }
        if stores.isEmpty { throw ConfigError.badShopping("\"shopping.stores\" must list at least one store") }
        let ids = stores.map(\.id)
        if ids.contains("") { throw ConfigError.badShopping("a store has an empty id") }
        if Set(ids).count != ids.count { throw ConfigError.badShopping("\"shopping.stores\" has a duplicate id") }
        if !ids.contains(defaultStore) { throw ConfigError.badShopping("\"shopping.defaultStore\" \"\(defaultStore)\" is not a store id") }
        for key in storeKeywords.keys.sorted() where !ids.contains(key) {
            throw ConfigError.badShopping("\"shopping.storeKeywords\" key \"\(key)\" is not a store id")
        }
        for key in categories.keys.sorted() {
            guard let cat = ShoppingItem.Category(rawValue: key), cat != .other else {
                throw ConfigError.badShopping("\"shopping.categories\" key \"\(key)\" is not a category")
            }
        }
        if (Array(storeKeywords.values) + Array(categories.values)).contains(where: { $0.contains("") }) {
            throw ConfigError.badShopping("a keyword is empty")
        }
    }
}

/// The album title is private: never log it.
public struct PhotosConfig: Decodable, Sendable, Equatable {
    public let album: String

    public init(album: String) {
        self.album = album
    }

    func validate() throws {
        if album.isEmpty { throw ConfigError.badPhotos("\"photos.album\" is empty") }
    }
}

/// The bridge address is private: never log it. The application key and pinned cert are in the Keychain.
public struct HueConfig: Decodable, Sendable, Equatable {
    /// Host or IP only: no scheme or path.
    public let bridge: String
    /// Scene name -> icon name in the dashboard's icons.js.
    public let sceneIcons: [String: String]

    public init(bridge: String, sceneIcons: [String: String] = [:]) {
        self.bridge = bridge
        self.sceneIcons = sceneIcons
    }

    private enum CodingKeys: String, CodingKey { case bridge, sceneIcons }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bridge = try c.decode(String.self, forKey: .bridge)
        sceneIcons = try c.decodeIfPresent([String: String].self, forKey: .sceneIcons) ?? [:]
    }

    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && !host.contains { $0 == "/" || $0.isWhitespace }
    }

    func validate() throws {
        if !Self.isValidHost(bridge) { throw ConfigError.badHue("\"hue.bridge\" must be a host name or IP, with no scheme, path or spaces") }
        if sceneIcons.contains(where: { $0.key.isEmpty || $0.value.isEmpty }) {
            throw ConfigError.badHue("\"hue.sceneIcons\" has an empty name or icon")
        }
    }
}

/// The speaker address and room name are private: never log them.
public struct SonosConfig: Decodable, Sendable, Equatable {
    /// Host or IP of any speaker in the room's group: no scheme, path or port.
    public let host: String
    /// The room name as the Sonos app shows it.
    public let room: String

    public init(host: String, room: String) {
        self.host = host
        self.room = room
    }

    func validate() throws {
        if host.isEmpty || host.contains(where: { $0 == "/" || $0 == ":" || $0.isWhitespace }) {
            throw ConfigError.badSonos("\"sonos.host\" must be a host name or IP, with no scheme, path, port or spaces")
        }
        if room.isEmpty { throw ConfigError.badSonos("\"sonos.room\" is empty") }
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
    case badShopping(String)
    case badPhotos(String)
    case badHue(String)
    case badSonos(String)

    public var description: String {
        switch self {
        case .unreadable(let path): "cannot read file at \(path)"
        case .malformed(let detail): "malformed JSON: \(detail)"
        case .noFrames: "\"frames\" must list at least one frame"
        case .badDashboardDir: "\"dashboardDir\" must be an absolute path"
        case .badWeather(let field): "\"weather.\(field)\" is out of range"
        case .badCalendar(let detail): "calendar config: \(detail)"
        case .badShopping(let detail): "shopping config: \(detail)"
        case .badPhotos(let detail): "photos config: \(detail)"
        case .badHue(let detail): "hue config: \(detail)"
        case .badSonos(let detail): "sonos config: \(detail)"
        case .badHash(let frame): "frame \"\(frame)\" needs a 64-character lowercase hex SHA-256 hash"
        }
    }
}
