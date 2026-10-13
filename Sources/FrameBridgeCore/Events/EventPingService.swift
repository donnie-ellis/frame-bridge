import ServiceLifecycle

/// Sends a `: ping` comment every 25 s until shutdown, then ends the open streams.
struct EventPingService: Service {
    let hub: EventHub
    var interval: Duration = .seconds(25)

    func run() async throws {
        do {
            try await cancelWhenGracefulShutdown {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    await hub.ping()
                }
            }
        } catch {
            await hub.finishAll()
            throw error
        }
        await hub.finishAll()
    }
}
