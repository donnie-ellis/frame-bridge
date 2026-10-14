import Foundation

/// Daily sampling and the "On this day" date ranges.
enum PhotoSampling {
    static let albumLimit = 300
    static let onThisDayLimit = 30

    /// FNV-1a over the day string. Not `Hasher`, which is randomized per process.
    static func seed(forDay day: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in day.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
    }

    /// Sorted by id first, since fetch order isn't guaranteed, then shuffled with the seed.
    static func sample(album: [AssetValues], onThisDay: [AssetValues], seed: UInt64) -> [AssetValues] {
        var rng = SplitMix64(seed: seed)
        let fromAlbum = Array(album.sorted { $0.id < $1.id }.shuffled(using: &rng).prefix(albumLimit))
        let chosen = Set(fromAlbum.map(\.id))
        let extra = onThisDay.sorted { $0.id < $1.id }.shuffled(using: &rng).filter { !chosen.contains($0.id) }
        return fromAlbum + extra.prefix(onThisDayLimit)
    }

    /// Today's month and day in each earlier year, from `oldestYear`: [local midnight, next midnight).
    /// Years without that day (Feb 29) are skipped. `Calendar` would roll them over to Mar 1.
    static func onThisDayRanges(today: Date, oldestYear: Int, calendar: Calendar) -> [DateInterval] {
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let thisYear = now.year, oldestYear < thisYear else { return [] }
        return (oldestYear..<thisYear).compactMap { year in
            let wanted = DateComponents(year: year, month: now.month, day: now.day)
            guard let date = calendar.date(from: wanted) else { return nil }
            let got = calendar.dateComponents([.year, .month, .day], from: date)
            guard got.year == year, got.month == now.month, got.day == now.day else { return nil }
            let start = calendar.startOfDay(for: date)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    static func nextLocalMidnight(after date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
    }
}
