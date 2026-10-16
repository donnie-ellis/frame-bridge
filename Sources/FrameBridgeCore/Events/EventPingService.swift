import ServiceLifecycle

/// Sends a `: ping` comment every 25 s until shutdown, then ends the open streams.
struct EventPingService: Service {
    let hub: EventHub
    var interval: Duration = .seconds(25)

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                // A cancelled sleep is the shutdown request, not a failure.
                do { try await Task.sleep(for: interval) } catch { break }
                await hub.ping()
            }
        }
        await hub.finishAll()
    }
}
