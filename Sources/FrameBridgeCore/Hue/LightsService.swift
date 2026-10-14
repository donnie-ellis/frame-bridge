import Logging
import ServiceLifecycle

/// Reads the lights once at startup, then every minute so /healthz stays fresh. Stands in for
/// the Hue event stream until that is built.
struct LightsService: Service {
    let feed: LightsFeed
    var logger = Logger(label: "frame-bridge.lights")

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do throws(APIError) {
                    _ = try await feed.state()
                    logger.info("lights read ok")
                } catch {
                    logger.warning("lights read failed", metadata: ["reason": .string(error.detail ?? error.error)])
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}
