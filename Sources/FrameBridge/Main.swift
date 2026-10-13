import FrameBridgeCore
import Foundation

@main
struct Main {
    static func main() async throws {
        let url = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? Config.defaultPath()
        let config: Config
        do {
            config = try Config.load(from: url)
        } catch {
            FileHandle.standardError.write(Data("frame-bridge: config \(url.path): \(error)\n".utf8))
            exit(1)
        }
        try await buildApplication(config: config).runService()
    }
}
