import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

/// Records what a logger was asked to write.
struct CapturingLogHandler: LogHandler {
    struct Entry: Sendable {
        let level: Logger.Level
        let message: String
        let metadata: Logger.Metadata
    }

    final class Box: Sendable {
        private let storage = OSAllocatedUnfairLock<[Entry]>(initialState: [])
        var entries: [Entry] { storage.withLock { $0 } }
        func add(_ entry: Entry) { storage.withLock { $0.append(entry) } }
    }

    let box: Box
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    init(_ box: Box) { self.box = box }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        box.add(Entry(level: event.level, message: "\(event.message)", metadata: event.metadata ?? [:]))
    }

    static func logger() -> (Logger, Box) {
        let box = Box()
        return (Logger(label: "test") { _ in CapturingLogHandler(box) }, box)
    }
}
