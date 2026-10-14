import Foundation
import Testing

@testable import FrameBridgeCore

private func many(_ n: Int, prefix: String) -> [AssetValues] {
    (0..<n).map { asset("\(prefix)/\($0)") }
}

@Test func albumSampleCapsAt300AndIsStablePerSeed() {
    let album = many(500, prefix: "A")
    let a = PhotoSampling.sample(album: album, onThisDay: [], seed: 1)
    #expect(a.count == 300)
    #expect(a == PhotoSampling.sample(album: album, onThisDay: [], seed: 1))
    #expect(a.map(\.id) != PhotoSampling.sample(album: album, onThisDay: [], seed: 2).map(\.id))
    #expect(a == PhotoSampling.sample(album: album.reversed(), onThisDay: [], seed: 1))
}

@Test func seedIsStableAcrossProcesses() {
    #expect(PhotoSampling.seed(forDay: "2026-10-13") == 0x37c8343a7a9ef5e6)
    #expect(PhotoSampling.seed(forDay: "") == 0xcbf2_9ce4_8422_2325)
    #expect(PhotoSampling.seed(forDay: "a") == 0xaf63_dc4c_8601_ec8c)
    #expect(PhotoSampling.seed(forDay: "2026-10-13") != PhotoSampling.seed(forDay: "2026-10-14"))
}

@Test func onThisDayCapsAt30AndDedupes() {
    let album = many(10, prefix: "A")
    let sample = PhotoSampling.sample(album: album, onThisDay: many(40, prefix: "T") + [album[3]], seed: 7)
    #expect(sample.count == 40)
    #expect(Set(sample.map(\.id)).count == sample.count)
    #expect(sample.filter { $0.id.hasPrefix("T") }.count == 30)
}

private func cal(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

@Test func onThisDayRangesCoverEachEarlierYear() throws {
    let c = cal("America/Chicago")
    let today = try #require(c.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 15)))
    let ranges = PhotoSampling.onThisDayRanges(today: today, oldestYear: 2027, calendar: c)
    #expect(ranges.count == 3)
    for (range, year) in zip(ranges, 2027...2029) {
        let s = c.dateComponents([.year, .month, .day, .hour, .minute], from: range.start)
        #expect(s.year == year && s.month == 3 && s.day == 10 && s.hour == 0 && s.minute == 0)
        #expect(range.end == c.date(byAdding: .day, value: 1, to: range.start))
    }
    // 2029-03-11 is the US spring-forward day: the range is 23 hours long.
    let dst = PhotoSampling.onThisDayRanges(today: try #require(c.date(from: DateComponents(year: 2030, month: 3, day: 11, hour: 15))), oldestYear: 2029, calendar: c)
    #expect(dst.count == 1)
    #expect(dst[0].duration == 23 * 3600)
    #expect(PhotoSampling.onThisDayRanges(today: today, oldestYear: 2030, calendar: c).isEmpty)
}

@Test func onThisDayRangesSkipNonLeapYearsOnFeb29() throws {
    let c = cal("UTC")
    let today = try #require(c.date(from: DateComponents(year: 2032, month: 2, day: 29, hour: 12)))
    let ranges = PhotoSampling.onThisDayRanges(today: today, oldestYear: 2027, calendar: c)
    #expect(ranges.map { c.component(.year, from: $0.start) } == [2028])
}

@Test func nextLocalMidnightIsTheNextStartOfDay() throws {
    let c = cal("America/Chicago")
    let now = try #require(c.date(from: DateComponents(year: 2030, month: 6, day: 5, hour: 23, minute: 59)))
    let next = PhotoSampling.nextLocalMidnight(after: now, calendar: c)
    #expect(c.dateComponents([.month, .day, .hour, .minute], from: next) == DateComponents(month: 6, day: 6, hour: 0, minute: 0))
}
