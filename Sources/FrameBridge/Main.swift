import FrameBridgeCore
import Foundation

@main
struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "hue-pair" {
            guard args.count > 2 else {
                FileHandle.standardError.write(Data("usage: FrameBridge hue-pair <bridge ip>\n".utf8))
                exit(2)
            }
            do {
                try await runHuePairing(bridge: args[2]) { question in
                    print(question, terminator: "")
                    return readLine()
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("frame-bridge: hue-pair: \(error)\n".utf8))
                exit(1)
            }
        }
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
