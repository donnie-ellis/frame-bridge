import CoreGraphics
import Foundation

/// Where the pixels come from. The real one is PhotoKit; tests use a generated image.
protocol ImageSource: Sendable {
    func image(id: String, maxEdge: Int) async throws -> CGImage
}

/// Resized JPEGs on disk. Two requests for the same uncached image share one render.
public actor ImageCache {
    private let directory: URL
    private let source: any ImageSource
    private var inFlight: [String: Task<Data, any Error>] = [:]

    init(directory: URL, source: any ImageSource) {
        self.directory = directory
        self.source = source
    }

    func jpeg(id: String, size: ImageSize) async throws(APIError) -> Data {
        let name = ImageSizing.cacheFileName(id: id, size: size)
        let file = directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file) { return data }
        let task: Task<Data, any Error>
        if let running = inFlight[name] {
            task = running
        } else {
            let source = source, directory = directory
            task = Task {
                let image = try await source.image(id: id, maxEdge: size.maxEdge)
                let data = try ImageSizing.jpeg(from: image, maxEdge: size.maxEdge)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return data
            }
            inFlight[name] = task
        }
        do {
            let data = try await task.value
            inFlight[name] = nil
            return data
        } catch {
            inFlight[name] = nil
            throw .sourceUnavailable("photo image unavailable")
        }
    }

    /// Deletes cached images of ids that are no longer in the list.
    func prune(keeping ids: [String]) {
        let keep = Set(ids.map(ImageSizing.idHash))
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jpg" {
            let prefix = file.lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
            if !keep.contains(prefix) { try? FileManager.default.removeItem(at: file) }
        }
    }
}
