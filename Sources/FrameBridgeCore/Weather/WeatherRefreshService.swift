import ServiceLifecycle

/// Refreshes the forecast about every 30 minutes until shutdown.
struct WeatherRefreshService: Service {
    let store: WeatherStore
    var interval: Duration = .seconds(1800)

    func run() async throws {
        try await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                await store.refresh()
                try await Task.sleep(for: interval)
            }
        }
    }
}
