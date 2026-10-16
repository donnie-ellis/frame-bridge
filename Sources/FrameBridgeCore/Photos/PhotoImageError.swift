import Foundation

/// Why a photo image couldn't be made. Logged, so it never holds a photo id, path or place: only
/// flags and `NSError` domains and codes.
enum PhotoImageError: Error, Equatable, CustomStringConvertible {
    case notAuthorized(FeedHealth.Authorization)
    case assetNotFound
    /// PhotoKit's result handler gave no image data. `error` is `PHImageErrorKey` as "domain code".
    case noImage(inCloud: Bool, degraded: Bool, error: String?)
    case cancelled(error: String?)
    /// PhotoKit gave image data that ImageIO couldn't decode.
    case undecodable
    case timedOut
    /// The cached JPEG couldn't be read back (focus detection).
    case unreadableJPEG

    /// The result handler's `info` values, as plain values so it can be tested without PhotoKit.
    static func failure(cancelled: Bool, inCloud: Bool, degraded: Bool, error: (any Error)?) -> PhotoImageError {
        let code = error.map(errorCode)
        if cancelled { return .cancelled(error: code) }
        return .noImage(inCloud: inCloud, degraded: degraded, error: code)
    }

    /// "domain code", plus the underlying error's when there is one. Never `localizedDescription`
    /// or `userInfo`, which can hold file paths.
    static func errorCode(_ error: any Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    var description: String {
        switch self {
        case .notAuthorized(let auth): "not authorized (\(auth.rawValue))"
        case .assetNotFound: "asset not found"
        case .noImage(let inCloud, let degraded, let error):
            "no image (inCloud=\(inCloud) degraded=\(degraded) error=\(error ?? "none"))"
        case .cancelled(let error): "cancelled (error=\(error ?? "none"))"
        case .undecodable: "image data undecodable"
        case .timedOut: "timed out"
        case .unreadableJPEG: "cached JPEG unreadable"
        }
    }

    /// The 503's `detail`: short and non-identifying.
    var detail: String {
        switch self {
        case .notAuthorized: "photos access not granted"
        case .assetNotFound: "photo not in the library"
        case .noImage(inCloud: true, _, _): "photo not downloaded from iCloud"
        case .noImage: "Photos returned no image"
        case .cancelled: "photo image request cancelled"
        case .undecodable, .unreadableJPEG: "photo image could not be decoded"
        case .timedOut: "photo image request timed out"
        }
    }

    /// A log reason for any error the photos code sees.
    static func logReason(_ error: any Error) -> String {
        switch error {
        case let error as PhotoImageError: error.description
        case let error as APIError: error.detail ?? error.error
        case is ImageSizing.EncodeError: "JPEG encoding failed"
        default: errorCode(error)
        }
    }
}
