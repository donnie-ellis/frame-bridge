import Logging
import ServiceLifecycle

/// Seconds to wait before reconnecting to the Hue event stream: 1, 2, 4 ... capped at 60.
enum HueBackoff {
    static func delay(_ failures: Int) -> Duration {
        .seconds(min(60, 1 << max(0, min(failures - 1, 6))))
    }
}

/// Keeps the Hue event stream open and feeds it to the lights feed, reconnecting with backoff.
struct LightsService: Service {
    let feed: LightsFeed
    let transport: any HueEventStreamTransport
    var logger = Logger(label: "frame-bridge.lights")
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func run() async throws {
        await cancelWhenGracefulShutdown { await connectLoop() }
    }

    func connectLoop() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                // Stream first, read second, so nothing in between is missed.
                let stream = try await transport.eventStream()
                try await feed.streamOpened()
                failures = 0
                logger.info("hue event stream connected")
                var parser = HueEventStreamParser()
                for try await chunk in stream {
                    for message in parser.feed(chunk) { await feed.apply(payload: message) }
                }
                await feed.streamClosed(reason: "Hue event stream closed")
                logger.warning("hue event stream closed")
                do { try await sleep(.seconds(1)) } catch { return }
            } catch {
                if Task.isCancelled { return }
                let reason = LightsFeed.reason(for: error)
                await feed.streamClosed(reason: reason)
                failures += 1
                logger.warning("hue event stream failed", metadata: ["reason": .string(reason)])
                do { try await sleep(HueBackoff.delay(failures)) } catch { return }
            }
        }
    }
}
