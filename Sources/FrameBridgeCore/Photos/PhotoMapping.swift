import Foundation

/// What the mapping needs from a PHAsset. The adapter fills it, tests build it directly.
struct AssetValues: Sendable, Equatable {
    var id: String
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var latitude: Double?
    var longitude: Double?
    var isFavorite: Bool
    var isImage: Bool
    var isScreenshot: Bool
}

/// A cached geocode result. Both fields nil is a cached "no result", so it isn't retried forever.
struct PlaceInfo: Codable, Sendable, Equatable {
    var place: String?
    var timeZone: String?
}

/// Plain asset values -> `Photo`. Private data: nothing here logs.
enum PhotoMapping {
    /// No videos, no screenshots, and nothing without a capture date.
    static func eligible(_ values: [AssetValues]) -> [AssetValues] {
        values.filter { $0.isImage && !$0.isScreenshot && $0.creationDate != nil }
    }

    /// Square counts as landscape.
    static func orientation(width: Int, height: Int) -> Photo.Orientation {
        width >= height ? .l : .p
    }

    /// `YYYY-MM-DD` in the place's zone when known, else the fallback (the Mac's).
    static func localDate(_ date: Date, placeTimeZone: TimeZone?, fallback: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = placeTimeZone ?? fallback
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Locality, else the first area of interest, else the county or state. Empty counts as missing.
    static func shortPlaceName(locality: String?, areasOfInterest: [String]?, subAdministrativeArea: String?, administrativeArea: String?) -> String? {
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        return nonEmpty(locality)
            ?? areasOfInterest?.lazy.compactMap { nonEmpty($0) }.first
            ?? nonEmpty(subAdministrativeArea)
            ?? nonEmpty(administrativeArea)
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    struct TagInput {
        var id: String
        var date: String
        var creationDate: Date
        var latitude: Double?
        var longitude: Double?
    }

    static let tagRadiusKm = 2.0

    private static func before(_ a: TagInput, _ b: TagInput) -> Bool {
        (a.creationDate, a.id) < (b.creationDate, b.id)
    }

    /// `<date>-<N>`. Within a day, located photos join the first group whose first photo is within
    /// 2 km, and all photos without a location form one more group. Groups are numbered by their
    /// earliest photo, so the result doesn't depend on input order.
    static func tags(for inputs: [TagInput]) -> [String: String] {
        var result: [String: String] = [:]
        for (date, day) in Dictionary(grouping: inputs, by: \.date) {
            var clusters: [[TagInput]] = []
            for p in day.filter({ $0.latitude != nil && $0.longitude != nil }).sorted(by: before) {
                if let i = clusters.firstIndex(where: {
                    distanceKm($0[0].latitude!, $0[0].longitude!, p.latitude!, p.longitude!) <= tagRadiusKm
                }) {
                    clusters[i].append(p)
                } else {
                    clusters.append([p])
                }
            }
            let unlocated = day.filter { $0.latitude == nil || $0.longitude == nil }.sorted(by: before)
            if !unlocated.isEmpty { clusters.append(unlocated) }
            for (n, group) in clusters.sorted(by: { before($0[0], $1[0]) }).enumerated() {
                for p in group { result[p.id] = "\(date)-\(n + 1)" }
            }
        }
        return result
    }

    /// `places` is the geocode cache: a missing or negative entry omits `place` and the date falls
    /// back to the Mac's zone. `fav` is passed through as read.
    static func photos(_ values: [AssetValues], places: [String: PlaceInfo], macTimeZone: TimeZone) -> [Photo] {
        let dated: [(AssetValues, Date, String)] = values.compactMap { v in
            guard let created = v.creationDate else { return nil }
            let zone = places[v.id]?.timeZone.flatMap { TimeZone(identifier: $0) }
            return (v, created, localDate(created, placeTimeZone: zone, fallback: macTimeZone))
        }
        let tags = tags(for: dated.map { TagInput(id: $0.0.id, date: $0.2, creationDate: $0.1, latitude: $0.0.latitude, longitude: $0.0.longitude) })
        return dated.map { v, _, date in
            Photo(id: v.id, o: orientation(width: v.pixelWidth, height: v.pixelHeight), date: date, place: places[v.id]?.place, tag: tags[v.id] ?? date + "-1", fav: v.isFavorite)
        }
    }
}
