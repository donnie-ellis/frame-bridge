import Foundation

/// `ChangeNotice` in the contract: something changed, re-fetch.
struct ChangeNotice: Encodable, Equatable, Sendable {
    let changedAt: String

    static func now(timeZone: TimeZone = .current) -> ChangeNotice {
        ChangeNotice(changedAt: WireDate.string(from: Date(), timeZone: timeZone))
    }
}
