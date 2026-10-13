import Foundation

/// Startup config, read once from a JSON file outside the repo.
public struct Config: Decodable, Sendable {
    /// Frame name -> lowercase hex SHA-256 of that frame's token.
    public let frames: [String: String]

    /// Absolute path of the built dashboard that is served at `/`.
    public let dashboardDir: String

    public init(frames: [String: String], dashboardDir: String) {
        self.frames = frames
        self.dashboardDir = dashboardDir
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

/// Messages name the frame, never the hash.
public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case malformed(String)
    case noFrames
    case badHash(frame: String)
    case badDashboardDir

    public var description: String {
        switch self {
        case .unreadable(let path): "cannot read file at \(path)"
        case .malformed(let detail): "malformed JSON: \(detail)"
        case .noFrames: "\"frames\" must list at least one frame"
        case .badDashboardDir: "\"dashboardDir\" must be an absolute path"
        case .badHash(let frame): "frame \"\(frame)\" needs a 64-character lowercase hex SHA-256 hash"
        }
    }
}
