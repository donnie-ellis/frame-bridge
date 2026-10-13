import Foundation

enum CalendarQuery {
    static let maxDays = 120

    /// `from` and `to` must carry a zone designator (`Z` or an offset): no default zone is assumed.
    static func parse(from: String?, to: String?, timeZone: TimeZone) throws(APIError) -> (from: Date, to: Date) {
        guard let from else { throw .badRequest("missing from") }
        guard let to else { throw .badRequest("missing to") }
        guard let start = date(from) else { throw .badRequest("from is not ISO 8601 with an offset") }
        guard let end = date(to) else { throw .badRequest("to is not ISO 8601 with an offset") }
        guard start < end else { throw .badRequest("from must be before to") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let limit = calendar.date(byAdding: .day, value: maxDays, to: start), end > limit {
            throw .badRequest("range exceeds \(maxDays) days")
        }
        return (start, end)
    }

    private static func date(_ text: String) -> Date? {
        guard hasZone(text) else { return nil }
        for fractional in [false, true] {
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: fractional)
            if let d = try? style.parse(text) { return d }
        }
        // ±HHMM without a colon.
        if let tail = text.suffix(5).first, tail == "+" || tail == "-", text.suffix(4).allSatisfy(\.isNumber) {
            let fixed = text.dropLast(2) + ":" + text.suffix(2)
            return date(String(fixed))
        }
        return nil
    }

    private static func hasZone(_ text: String) -> Bool {
        if text.hasSuffix("Z") || text.hasSuffix("z") { return true }
        let chars = Array(text)
        if chars.count > 6, chars[chars.count - 6] == "+" || chars[chars.count - 6] == "-", chars[chars.count - 3] == ":" { return true }
        if chars.count > 5, chars[chars.count - 5] == "+" || chars[chars.count - 5] == "-" { return chars.suffix(4).allSatisfy(\.isNumber) }
        return false
    }
}
