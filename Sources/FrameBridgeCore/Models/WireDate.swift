import Foundation

/// ISO 8601 with the zone's UTC offset (`2026-10-12T14:00:00-04:00`), never `Z`.
enum WireDate {
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard, timeSeparator: .colon, timeZoneSeparator: .colon, includingFractionalSeconds: false, timeZone: timeZone))
    }
}
