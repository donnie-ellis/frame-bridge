import CoreFoundation
import Foundation

/// `LightPatch` in the contract: any of `on`, `level`, `temp` and `color`, but not `temp` with `color`.
struct LightPatch: Equatable, Sendable {
    var on: Bool?
    var level: Int?
    var temp: Int?
    var color: String?

    static func parse(_ data: Data) throws(APIError) -> LightPatch {
        let dict = try object(data, keys: ["on", "level", "temp", "color"], hint: "send \"on\", \"level\", \"temp\" or \"color\"")
        var patch = LightPatch()
        (patch.on, patch.level) = try onAndLevel(dict)
        if let value = dict["temp"] {
            guard let temp = integer(value) else { throw .badRequest("\"temp\" must be an integer") }
            patch.temp = temp
        }
        if let value = dict["color"] {
            guard let color = value as? String, color.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil else {
                throw .badRequest("\"color\" must be lowercase #rrggbb")
            }
            guard color != "#000000" else { throw .badRequest("color has no hue") }
            patch.color = color
        }
        if patch.temp != nil && patch.color != nil { throw .badRequest("send temp or color, not both") }
        return patch
    }

    fileprivate static func object(_ data: Data, keys: Set<String>, hint: String) throws(APIError) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw .badRequest("body must be a JSON object")
        }
        if dict.isEmpty { throw .badRequest(hint) }
        if let extra = dict.keys.sorted().first(where: { !keys.contains($0) }) {
            throw .badRequest("unknown field \"\(extra)\"")
        }
        return dict
    }

    fileprivate static func onAndLevel(_ dict: [String: Any]) throws(APIError) -> (Bool?, Int?) {
        var on: Bool?
        var level: Int?
        if let value = dict["on"] {
            guard isBool(value), let flag = value as? Bool else { throw .badRequest("\"on\" must be a boolean") }
            on = flag
        }
        if let value = dict["level"] {
            guard let number = integer(value) else { throw .badRequest("\"level\" must be an integer") }
            guard (1...100).contains(number) else { throw .badRequest("\"level\" must be between 1 and 100") }
            level = number
        }
        return (on, level)
    }

    /// Booleans bridge to NSNumber too, so tell them apart first.
    private static func integer(_ value: Any) -> Int? {
        guard !isBool(value), let number = value as? NSNumber, !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }

    static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// `RoomPatch` in the contract: `on`, `level`, or both.
struct RoomPatch: Equatable, Sendable {
    var on: Bool?
    var level: Int?

    static func parse(_ data: Data) throws(APIError) -> RoomPatch {
        let dict = try LightPatch.object(data, keys: ["on", "level"], hint: "send \"on\", \"level\" or both")
        let (on, level) = try LightPatch.onAndLevel(dict)
        return RoomPatch(on: on, level: level)
    }
}
