import Foundation

/// One SSE message, named as in the contract's table.
enum ServerEvent: Sendable {
    case calendar(ChangeNotice)
    case shopping(ChangeNotice)
    case chores(ChangeNotice)
    case weather(ChangeNotice)
    case photos(ChangeNotice)
    case light(Light)
    case room(Room)
    case scene(Scene)
    case lights(ChangeNotice)
    case nowplaying(NowPlaying)

    var name: String {
        switch self {
        case .calendar: "calendar"
        case .shopping: "shopping"
        case .chores: "chores"
        case .weather: "weather"
        case .photos: "photos"
        case .light: "light"
        case .room: "room"
        case .scene: "scene"
        case .lights: "lights"
        case .nowplaying: "nowplaying"
        }
    }

    /// `event:` and `data:` lines, `data` as one line of compact JSON.
    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data: Data
        switch self {
        case .calendar(let n), .shopping(let n), .chores(let n), .weather(let n), .photos(let n), .lights(let n): data = try encoder.encode(n)
        case .light(let l): data = try encoder.encode(l)
        case .room(let r): data = try encoder.encode(r)
        case .scene(let s): data = try encoder.encode(s)
        case .nowplaying(let n): data = try encoder.encode(n)
        }
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }
}

enum SSE {
    static let retry = "retry: 5000\n\n"
    static let ping = ": ping\n\n"
}
