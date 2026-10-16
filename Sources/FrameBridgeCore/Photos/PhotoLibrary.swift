import Foundation
import Logging
import AppKit
import Photos

/// The PhotoKit adapter. Read only: nothing here calls performChanges or sets a favorite.
// @unchecked: PHFetchResult isn't Sendable. The held results are only touched under `lock`.
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver, PhotoProvider, @unchecked Sendable {
    private let logger: Logger
    private let lock = NSLock()
    private var _unavailableReason: String?
    private var onChange: (@Sendable () -> Void)?
    private var registered = false
    private var heldCollections: PHFetchResult<PHAssetCollection>?
    private var heldAlbum: PHFetchResult<PHAsset>?
    private var heldOnThisDay: [PHFetchResult<PHAsset>] = []

    init(logger: Logger = Logger(label: "frame-bridge.photos")) {
        self.logger = logger
    }

    func unavailableReason() async -> String? { lock.withLock { _unavailableReason } }

    /// Asking for access from a binary without the privacy string kills the process, so `swift run`
    /// skips it. The .app bundle has the string.
    func requestAccess() async {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else {
            lock.withLock { _unavailableReason = "not running from the .app bundle" }
            logger.warning("not running from the .app bundle, skipping the photos access request")
            return
        }
        // PhotoKit has no read-only level.
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func authorization(_ status: PHAuthorizationStatus) -> FeedHealth.Authorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    func authorization() async -> FeedHealth.Authorization {
        Self.authorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Registers once. `onChange` fires only for changes to what the last rebuild fetched.
    func startObserving(onChange: @escaping @Sendable () -> Void) {
        let first = lock.withLock {
            self.onChange = onChange
            defer { registered = true }
            return !registered
        }
        if first { PHPhotoLibrary.shared().register(self) }
    }

    func stopObserving() {
        let was = lock.withLock {
            defer { registered = false; onChange = nil }
            return registered
        }
        if was { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    var isObserving: Bool { lock.withLock { registered } }

    private func values(_ asset: PHAsset) -> AssetValues {
        let coordinate = asset.location?.coordinate
        return AssetValues(
            id: asset.localIdentifier,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            isFavorite: asset.isFavorite,
            isImage: asset.mediaType == .image,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )
    }

    private func values(_ result: PHFetchResult<PHAsset>) -> [AssetValues] {
        var out: [AssetValues] = []
        result.enumerateObjects { asset, _, _ in out.append(self.values(asset)) }
        return out
    }

    func albumAssets(title: String) async throws -> [AssetValues] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var match: PHAssetCollection?
        collections.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == title {
                match = collection
                stop.pointee = true
            }
        }
        lock.withLock { heldCollections = collections }
        guard let match else { throw PhotoSourceError.albumNotFound }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(in: match, options: options)
        lock.withLock { heldAlbum = result }
        return values(result)
    }

    func oldestCreationDate() async -> Date? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: .image, options: options).firstObject?.creationDate
    }

    func assets(in ranges: [DateInterval]) async throws -> [AssetValues] {
        var results: [PHFetchResult<PHAsset>] = []
        for range in ranges {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", range.start as NSDate, range.end as NSDate)
            results.append(PHAsset.fetchAssets(with: .image, options: options))
        }
        lock.withLock { heldOnThisDay = results }
        return results.flatMap { values($0) }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let (callback, relevant) = lock.withLock { () -> ((@Sendable () -> Void)?, Bool) in
            var hit = false
            if let c = heldCollections, changeInstance.changeDetails(for: c) != nil { hit = true }
            if let a = heldAlbum, changeInstance.changeDetails(for: a) != nil { hit = true }
            for r in heldOnThisDay where changeInstance.changeDetails(for: r) != nil { hit = true }
            return (onChange, hit)
        }
        if relevant { callback?() }
    }
}

/// Settles the image request exactly once, from the PhotoKit callback or the timeout.
private final class ImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private var finished = false
    private var requestID: PHImageRequestID?

    func start(_ continuation: CheckedContinuation<CGImage, any Error>) { lock.withLock { self.continuation = continuation } }
    func set(requestID: PHImageRequestID) { lock.withLock { self.requestID = requestID } }

    func finish(_ result: Result<CGImage, any Error>) {
        let (c, id) = lock.withLock { () -> (CheckedContinuation<CGImage, any Error>?, PHImageRequestID?) in
            guard !finished else { return (nil, nil) }
            finished = true
            return (continuation, requestID)
        }
        guard let c else { return }
        if case .failure = result, let id { PHImageManager.default().cancelImageRequest(id) }
        c.resume(with: result)
    }
}

extension PhotoLibrary: ImageSource {
    static let imageTimeout: Duration = .seconds(30)

    /// Read only: a fetch by identifier and one image data request. iCloud originals are downloaded.
    /// Not `requestImage`: on the Mac mini (Intel, macOS 15) it hands back no image and no error for
    /// every asset, while the data request works. ImageIO then decodes and shrinks the data.
    func image(id: String, maxEdge: Int) async throws -> CGImage {
        let auth = await authorization()
        guard auth == .authorized || auth == .limited else { throw PhotoImageError.notAuthorized(auth) }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw PhotoImageError.assetNotFound }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let request = ImageRequest()
        let timeout = Task {
            try await Task.sleep(for: Self.imageTimeout)
            request.finish(.failure(PhotoImageError.timedOut))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            request.start(continuation)
            let requestID = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                if !cancelled, let data {
                    if let image = ImageSizing.thumbnail(from: data, maxEdge: maxEdge) {
                        request.finish(.success(image))
                    } else {
                        request.finish(.failure(PhotoImageError.undecodable))
                    }
                } else {
                    request.finish(.failure(PhotoImageError.failure(
                        cancelled: cancelled,
                        inCloud: (info?[PHImageResultIsInCloudKey] as? Bool) == true,
                        degraded: (info?[PHImageResultIsDegradedKey] as? Bool) == true,
                        error: info?[PHImageErrorKey] as? any Error
                    )))
                }
            }
            request.set(requestID: requestID)
        }
    }
}
