import ServiceLifecycle

/// Polls the speaker until shutdown.
struct NowPlayingService: Service {
    let feed: NowPlayingFeed

    func run() async throws {
        try await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                let next = await feed.poll()
                try await Task.sleep(for: next)
            }
        }
    }
}
