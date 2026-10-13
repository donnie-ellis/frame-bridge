import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!

private func parse(_ from: String?, _ to: String?) throws -> (from: Date, to: Date) {
    try CalendarQuery.parse(from: from, to: to, timeZone: ny)
}

private func detail(_ from: String?, _ to: String?) -> String? {
    do { _ = try parse(from, to); return nil } catch let e as APIError { return e.detail } catch { return "other" }
}

@Test func queryAcceptsOffsetZAndFractional() throws {
    let a = try parse("2026-09-01T00:00:00-04:00", "2026-09-02T00:00:00-04:00")
    #expect(a.to.timeIntervalSince(a.from) == 86400)
    let z = try parse("2026-09-01T04:00:00Z", "2026-09-02T04:00:00.500Z")
    #expect(z.from == a.from)
    #expect(try parse("2026-09-01T00:00:00-0400", "2026-09-02T00:00:00-04:00").from == a.from)
}

@Test func queryRejectsBadInput() {
    #expect(detail(nil, "2026-09-02T00:00:00Z") == "missing from")
    #expect(detail("2026-09-01T00:00:00Z", nil) == "missing to")
    #expect(detail("garbage", "2026-09-02T00:00:00Z") == "from is not ISO 8601 with an offset")
    #expect(detail("2026-09-01T00:00:00Z", "2026-09-02") == "to is not ISO 8601 with an offset")
    #expect(detail("2026-09-01T00:00:00", "2026-09-02T00:00:00Z") == "from is not ISO 8601 with an offset")
    #expect(detail("2026-09-01T00:00:00Z", "2026-09-01T00:00:00Z") == "from must be before to")
    #expect(detail("2026-09-02T00:00:00Z", "2026-09-01T00:00:00Z") == "from must be before to")
}

@Test func queryLimitsRangeTo120Days() {
    #expect(detail("2026-09-01T00:00:00-04:00", "2026-12-30T00:00:00-05:00") == nil)
    #expect(detail("2026-09-01T00:00:00-04:00", "2026-12-31T00:00:00-05:00") == "range exceeds 120 days")
}
