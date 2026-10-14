import Foundation
import Logging
import ServiceLifecycle

/// Photos lifecycle: asks for access, builds the first list, forwards library changes (debounced)
/// and the daily re-sample as `photos` notices, and geocodes places in the background.
struct PhotosService: Service {
    let library: PhotoLibrary
    let feed: PhotosFeed
    let cache: PlaceCache
    let geocoder: any ReverseGeocoding
    let events: EventHub
    let debouncer = EventStoreDebouncer(interval: .seconds(2))
    var logger = Logger(label: "frame-bridge.photos")

    func run() async throws {
        await library.requestAccess()
        _ = await feed.rebuild()
        let feed = feed, events = events, debouncer = debouncer
        await debouncer.subscribe { if await feed.rebuild() { await events.photosChanged() } }
        await observeIfAuthorized()
        await cancelWhenGracefulShutdown {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await midnightLoop() }
                group.addTask { await geocodeLoop() }
            }
        }
        await debouncer.stop()
        library.stopObserving()
    }

    private func observeIfAuthorized() async {
        guard !library.isObserving else { return }
        let auth = await library.authorization()
        guard auth == .authorized || auth == .limited else { return }
        let debouncer = debouncer
        library.startObserving { Task { await debouncer.poke() } }
    }

    private func notifyIfChanged() async {
        if await feed.rebuild() { await events.photosChanged() }
    }

    /// The daily re-sample.
    private func midnightLoop() async {
        while !Task.isCancelled {
            let next = PhotoSampling.nextLocalMidnight(after: Date(), calendar: .current).addingTimeInterval(5)
            do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
            await notifyIfChanged()
            await observeIfAuthorized()
        }
    }

    /// At most one lookup a second. A failure (network, Apple's throttle) backs off for a minute.
    private func geocodeLoop() async {
        while !Task.isCancelled {
            let todo = await feed.uncachedLocated().prefix(50)
            var added = false
            var backOff = todo.isEmpty
            for asset in todo {
                guard let lat = asset.latitude, let lon = asset.longitude else { continue }
                do {
                    let info = try await geocoder.place(latitude: lat, longitude: lon)
                    try await cache.store(info, for: asset.id)
                    added = true
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError {
                    return
                } catch {
                    logger.warning("geocoding failed, backing off")
                    backOff = true
                    break
                }
            }
            if added { await notifyIfChanged() }
            if backOff {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}
