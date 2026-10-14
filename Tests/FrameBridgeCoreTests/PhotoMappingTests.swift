import Foundation
import Photos
import Testing

@testable import FrameBridgeCore

func asset(_ id: String, w: Int = 4000, h: Int = 3000, at date: Date? = Date(timeIntervalSince1970: 1_700_000_000), lat: Double? = nil, lon: Double? = nil, fav: Bool = false, image: Bool = true, screenshot: Bool = false) -> AssetValues {
    AssetValues(id: id, pixelWidth: w, pixelHeight: h, creationDate: date, latitude: lat, longitude: lon, isFavorite: fav, isImage: image, isScreenshot: screenshot)
}

private let utc = TimeZone(identifier: "UTC")!

@Test func orientationSquareIsLandscape() {
    #expect(PhotoMapping.orientation(width: 4000, height: 3000) == .l)
    #expect(PhotoMapping.orientation(width: 3000, height: 4000) == .p)
    #expect(PhotoMapping.orientation(width: 3000, height: 3000) == .l)
}

@Test func dateUsesPlaceZoneThenMacZone() {
    // 2030-01-02 03:30 UTC
    let instant = Date(timeIntervalSince1970: 1_893_555_000)
    let west = TimeZone(identifier: "America/Chicago")!
    let east = TimeZone(identifier: "Pacific/Auckland")!
    #expect(PhotoMapping.localDate(instant, placeTimeZone: west, fallback: utc) == "2030-01-01")
    #expect(PhotoMapping.localDate(instant, placeTimeZone: east, fallback: utc) == "2030-01-02")
    #expect(PhotoMapping.localDate(instant, placeTimeZone: nil, fallback: west) == "2030-01-01")
    let photos = PhotoMapping.photos([asset("a", at: instant)], places: ["a": PlaceInfo(place: nil, timeZone: "America/Chicago")], macTimeZone: utc)
    #expect(photos[0].date == "2030-01-01")
    #expect(PhotoMapping.photos([asset("a", at: instant)], places: [:], macTimeZone: utc)[0].date == "2030-01-02")
}

@Test func eligibleDropsVideosScreenshotsAndUndated() {
    let all = [asset("ok"), asset("video", image: false), asset("shot", screenshot: true), asset("nodate", at: nil)]
    #expect(PhotoMapping.eligible(all).map(\.id) == ["ok"])
}

private func tagged(_ items: [(String, Double?, Double?, TimeInterval)], day: String = "2030-01-02") -> [String: String] {
    let base = Date(timeIntervalSince1970: 1_893_555_000)
    return PhotoMapping.tags(for: items.map { PhotoMapping.TagInput(id: $0.0, date: day, creationDate: base.addingTimeInterval($0.3), latitude: $0.1, longitude: $0.2) })
}

@Test func tagsGroupBySameDayAndDistance() {
    let t = tagged([("a", 10.0, 20.0, 0), ("b", 10.005, 20.0, 60), ("c", 10.1, 20.0, 120)])
    #expect(t["a"] == "2030-01-02-1" && t["b"] == t["a"])
    #expect(t["c"] == "2030-01-02-2")
    let other = PhotoMapping.tags(for: [
        PhotoMapping.TagInput(id: "x", date: "2030-01-02", creationDate: Date(timeIntervalSince1970: 1), latitude: 10, longitude: 20),
        PhotoMapping.TagInput(id: "y", date: "2030-01-03", creationDate: Date(timeIntervalSince1970: 2), latitude: 10, longitude: 20),
    ])
    #expect(other["x"] != other["y"])
}

@Test func unlocatedPhotosShareOneTagPerDay() {
    let t = tagged([("a", 10.0, 20.0, 0), ("n1", nil, nil, 30), ("n2", nil, nil, 90), ("b", 10.0, 20.0, 120)])
    #expect(t["n1"] == t["n2"])
    #expect(t["n1"] != t["a"] && t["a"] == t["b"])
    #expect(t["n1"] == "2030-01-02-2")
}

@Test func tagsDoNotDependOnInputOrder() {
    let items: [(String, Double?, Double?, TimeInterval)] = [("a", 10, 20, 0), ("b", 11, 20, 10), ("c", nil, nil, 20), ("d", 10.001, 20, 30), ("e", 12, 21, 40)]
    let expected = tagged(items)
    for seed in 0..<5 {
        var rng = PhotoSampling.SplitMix64(seed: UInt64(seed))
        #expect(tagged(items.shuffled(using: &rng)) == expected)
    }
}

@Test func placeAndFavPassThroughAndNilPlaceIsOmitted() throws {
    let values = [asset("known", fav: true), asset("unknown"), asset("negative")]
    let places = ["known": PlaceInfo(place: "Madeupville", timeZone: nil), "negative": PlaceInfo(place: nil, timeZone: nil)]
    let photos = PhotoMapping.photos(values, places: places, macTimeZone: utc)
    #expect(photos.map(\.place) == ["Madeupville", nil, nil])
    #expect(photos.map(\.fav) == [true, false, false])
    let json = String(decoding: try JSONEncoder().encode(photos), as: UTF8.self)
    #expect(!json.contains("null"))
    #expect(json.components(separatedBy: "\"place\"").count == 2)
}

@Test func shortPlaceNameFallbacks() {
    #expect(PhotoMapping.shortPlaceName(locality: "Town", areasOfInterest: ["Park"], subAdministrativeArea: "County", administrativeArea: "State") == "Town")
    #expect(PhotoMapping.shortPlaceName(locality: "", areasOfInterest: ["", "Park"], subAdministrativeArea: "County", administrativeArea: "State") == "Park")
    #expect(PhotoMapping.shortPlaceName(locality: nil, areasOfInterest: nil, subAdministrativeArea: "County", administrativeArea: "State") == "County")
    #expect(PhotoMapping.shortPlaceName(locality: nil, areasOfInterest: [], subAdministrativeArea: "", administrativeArea: "State") == "State")
    #expect(PhotoMapping.shortPlaceName(locality: nil, areasOfInterest: nil, subAdministrativeArea: nil, administrativeArea: "") == nil)
}

@Test func authorizationMapsEveryStatus() {
    #expect(PhotoLibrary.authorization(.authorized) == .authorized)
    #expect(PhotoLibrary.authorization(.limited) == .limited)
    #expect(PhotoLibrary.authorization(.denied) == .denied)
    #expect(PhotoLibrary.authorization(.restricted) == .restricted)
    #expect(PhotoLibrary.authorization(.notDetermined) == .notDetermined)
}
