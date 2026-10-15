import Foundation

/// `ShoppingItemPatch` in the contract: `done`, required.
struct ShoppingItemPatch: Equatable, Sendable {
    var done: Bool

    static func parse(_ data: Data) throws(APIError) -> ShoppingItemPatch {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw .badRequest("body must be a JSON object")
        }
        if let extra = dict.keys.first(where: { $0 != "done" }) {
            throw .badRequest("unknown field \"\(extra)\"")
        }
        guard let value = dict["done"] else { throw .badRequest("send \"done\"") }
        guard LightPatch.isBool(value), let done = value as? Bool else { throw .badRequest("\"done\" must be a boolean") }
        return ShoppingItemPatch(done: done)
    }
}
