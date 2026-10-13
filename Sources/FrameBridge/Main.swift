import FrameBridgeCore

@main
struct Main {
    static func main() async throws {
        try await buildApplication().runService()
    }
}
