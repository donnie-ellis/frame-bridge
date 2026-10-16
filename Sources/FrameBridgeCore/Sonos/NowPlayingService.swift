import ServiceLifecycle

/// Polls the speaker until shutdown.
struct NowPlayingService: Service {
    let feed: NowPlayingFeed

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                let next = await feed.poll()
                // A cancelled sleep is the shutdown request, not a failure.
                do { try await Task.sleep(for: next) } catch { return }
            }
        }
    }
}
