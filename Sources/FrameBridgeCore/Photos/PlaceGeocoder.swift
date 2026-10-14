import CoreLocation
import Foundation

protocol ReverseGeocoding: Sendable {
    func place(latitude: Double, longitude: Double) async throws -> PlaceInfo
}

/// CLGeocoder, not MapKit: MKReverseGeocodingRequest needs macOS 26 and the Mac mini tops out at 15.
struct CLGeocoderSource: ReverseGeocoding {
    func place(latitude: Double, longitude: Double) async throws -> PlaceInfo {
        let geocoder = CLGeocoder()
        do {
            let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude))
            guard let mark = marks.first else { return PlaceInfo(place: nil, timeZone: nil) }
            return PlaceInfo(
                place: PhotoMapping.shortPlaceName(locality: mark.locality, areasOfInterest: mark.areasOfInterest, subAdministrativeArea: mark.subAdministrativeArea, administrativeArea: mark.administrativeArea),
                timeZone: mark.timeZone?.identifier
            )
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            return PlaceInfo(place: nil, timeZone: nil)
        }
    }
}
