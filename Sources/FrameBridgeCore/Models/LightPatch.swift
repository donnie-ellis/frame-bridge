import CoreFoundation
import Foundation

/// `LightPatch` in the contract: `on`, `level`, or both.
struct LightPatch: Equatable, Sendable {
    var on: Bool?
    var level: Int?

    static func parse(_ data: Data) throws(APIError) -> LightPatch {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw .badRequest("body must be a JSON object")
        }
        if dict.isEmpty { throw .badRequest("send \"on\", \"level\" or both") }
        if let extra = dict.keys.first(where: { $0 != "on" && $0 != "level" }) {
            throw .badRequest("unknown field \"\(extra)\"")
        }
        var patch = LightPatch()
        if let value = dict["on"] {
            guard isBool(value), let on = value as? Bool else { throw .badRequest("\"on\" must be a boolean") }
            patch.on = on
        }
        if let value = dict["level"] {
            // Booleans bridge to NSNumber too, so tell them apart first.
            guard !isBool(value), let number = value as? NSNumber, !CFNumberIsFloatType(number) else {
                throw .badRequest("\"level\" must be an integer")
            }
            let level = number.intValue
            guard (1...100).contains(level) else { throw .badRequest("\"level\" must be between 1 and 100") }
            patch.level = level
        }
        return patch
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
