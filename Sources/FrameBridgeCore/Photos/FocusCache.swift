import Foundation

/// A cached focus result. `focus` nil is a cached "nothing found", so it isn't retried forever.
struct FocusEntry: Codable, Sendable, Equatable {
    var focus: PhotoFocus?
}

/// Per-asset focus regions on disk (wire-ready, top-left origin), so the request path never runs Vision.
actor FocusCache: FocusLookup {
    private let file: URL
    private var entries: [String: FocusEntry]

    init(directory: URL) {
        file = directory.appendingPathComponent("focus.json")
        entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: FocusEntry].self, from: $0) } ?? [:]
    }

    func focus(for ids: [String]) -> [String: FocusEntry] {
        ids.reduce(into: [:]) { if let e = entries[$1] { $0[$1] = e } }
    }

    func store(_ entry: FocusEntry, for id: String) throws {
        entries[id] = entry
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
