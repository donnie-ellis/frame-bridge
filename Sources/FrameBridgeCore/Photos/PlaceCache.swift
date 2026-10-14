import Foundation

/// Per-asset geocode results on disk, so the request path never geocodes. Negative results are kept.
actor PlaceCache: PlaceLookup {
    private let file: URL
    private var entries: [String: PlaceInfo]

    init(directory: URL) {
        file = directory.appendingPathComponent("places.json")
        entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: PlaceInfo].self, from: $0) } ?? [:]
    }

    func places(for ids: [String]) -> [String: PlaceInfo] {
        ids.reduce(into: [:]) { if let e = entries[$1] { $0[$1] = e } }
    }

    func store(_ info: PlaceInfo, for id: String) throws {
        entries[id] = info
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
