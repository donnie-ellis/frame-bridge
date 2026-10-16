import Foundation
import Logging
import Testing

@testable import FrameBridgeCore

@Test func cancelledWinsOverEverythingElse() {
    let error = NSError(domain: "PHPhotosErrorDomain", code: 3072)
    #expect(PhotoImageError.failure(cancelled: true, inCloud: true, degraded: false, error: error) == .cancelled(error: "PHPhotosErrorDomain 3072"))
}

@Test func noImageKeepsTheCloudFlagsAndTheErrorCode() {
    let underlying = NSError(domain: NSURLErrorDomain, code: -1009)
    let error = NSError(domain: "PHPhotosErrorDomain", code: 3164, userInfo: [NSUnderlyingErrorKey: underlying])
    let failure = PhotoImageError.failure(cancelled: false, inCloud: true, degraded: false, error: error)
    #expect(failure == .noImage(inCloud: true, degraded: false, error: "PHPhotosErrorDomain 3164 (NSURLErrorDomain -1009)"))
    #expect(failure.detail == "photo not downloaded from iCloud")
}

@Test func noImageAndNoInfoIsStillAReason() {
    let failure = PhotoImageError.failure(cancelled: false, inCloud: false, degraded: false, error: nil)
    #expect(failure == .noImage(inCloud: false, degraded: false, error: nil))
    #expect(failure.description == "no image (inCloud=false degraded=false error=none)")
    #expect(failure.detail == "Photos returned no image")
}

@Test func errorCodeNeverIncludesUserInfo() {
    let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
        NSFilePathErrorKey: "/Users/someone/Pictures/Photos Library.photoslibrary/originals/7F04.heic",
        NSLocalizedDescriptionKey: "The file 7F04.heic couldn't be opened.",
    ])
    #expect(PhotoImageError.errorCode(error) == "NSCocoaErrorDomain 4")
}

@Test func imageCacheLogsTheReasonAndSizeButNotTheId() async throws {
    let log = CapturedLog()
    let source = StubImageSource()
    await source.set(failure: .noImage(inCloud: false, degraded: false, error: "PHPhotosErrorDomain 3303"))
    let cache = ImageCache(directory: tempDir(), source: source, logger: log.logger)
    let id = "7F046A0E-3E6F-482D-AF9A-A6511B8FECFC/L0/001"
    do {
        _ = try await cache.jpeg(id: id, size: .half)
        Issue.record("expected a failure")
    } catch {
        #expect(error.status == .serviceUnavailable)
        #expect(error.detail == "Photos returned no image")
    }
    let lines = log.lines
    #expect(lines.count == 1)
    #expect(lines.first?.contains("photo image failed") == true)
    #expect(lines.first?.contains("PHPhotosErrorDomain 3303") == true)
    #expect(lines.first?.contains("size=half") == true)
    #expect(!lines.joined().contains("7F046A0E"))
}

/// Collects formatted log lines (message plus `key=value` metadata) for assertions.
// @unchecked: `stored` is only touched under `lock`.
final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    var logger: Logger { Logger(label: "test") { _ in Handler(log: self) } }

    private func append(_ line: String) { lock.withLock { stored.append(line) } }

    struct Handler: LogHandler {
        let log: CapturedLog
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(level: Logger.Level, message: Logger.Message, metadata extra: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
            let all = metadata.merging(extra ?? [:]) { $1 }
            let text = ([message.description] + all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
            log.append(text)
        }
    }
}
