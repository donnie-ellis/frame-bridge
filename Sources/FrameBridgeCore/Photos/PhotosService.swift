import Foundation
import ImageIO
import Logging
import ServiceLifecycle

/// Photos lifecycle: asks for access, builds the first list, forwards library changes (debounced)
/// and the daily re-sample as `photos` notices, and computes places and focus regions in the background.
struct PhotosService: Service {
    let library: PhotoLibrary
    let feed: PhotosFeed
    let cache: PlaceCache
    let images: ImageCache
    let geocoder: any ReverseGeocoding
    let focusCache: FocusCache
    let detector: any FocusDetecting
    let events: EventHub
    let debouncer = EventStoreDebouncer(interval: .seconds(2))
    var logger = Logger(label: "frame-bridge.photos")

    func run() async throws {
        await library.requestAccess()
        _ = await feed.rebuild()
        await images.prune(keeping: await feed.currentIDs())
        let feed = feed, events = events, debouncer = debouncer, images = images
        await debouncer.subscribe {
            let changed = await feed.rebuild()
            await images.prune(keeping: await feed.currentIDs())
            if changed { await events.photosChanged() }
        }
        await observeIfAuthorized()
        await cancelWhenGracefulShutdown {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await midnightLoop() }
                group.addTask { await geocodeLoop() }
                group.addTask { await focusLoop() }
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
        let changed = await feed.rebuild()
        await images.prune(keeping: await feed.currentIDs())
        if changed { await events.photosChanged() }
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
                    logger.warning("geocoding failed, backing off", metadata: ["reason": .string(PhotoImageError.logReason(error))])
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

    /// Up to 10 photos a pass, one at a time, from the cached 1280 JPEG. A failure isn't cached
    /// (it is retried after a minute). No ids in logs.
    private func focusLoop() async {
        while !Task.isCancelled {
            let todo = await feed.unfocused().prefix(10)
            var stored = 0
            var failed = 0
            for id in todo {
                do {
                    let data = try await images.jpeg(id: id, size: .full)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { throw PhotoImageError.unreadableJPEG }
                    let focus = try await detector.focus(in: image)
                    try await focusCache.store(FocusEntry(focus: focus), for: id)
                    stored += 1
                } catch is CancellationError {
                    return
                } catch {
                    logger.warning("focus detection failed, will retry", metadata: ["reason": .string(PhotoImageError.logReason(error))])
                    failed += 1
                }
            }
            if stored > 0 {
                logger.info("computed focus for \(stored) photos")
                // Rebuild now, as geocodeLoop does: a debounced rebuild never fires while this loop
                // keeps poking it, so `unfocused()` would hand back the same ids forever.
                await notifyIfChanged()
            }
            if todo.isEmpty || failed > 0 {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}
