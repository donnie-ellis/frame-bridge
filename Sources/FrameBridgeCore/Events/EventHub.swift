import Foundation
import Logging

/// Fans SSE messages out to the connected frames. A frame that stops reading is dropped, so one
/// stuck connection never holds up the others.
public actor EventHub {
    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]
    private let timeZone: TimeZone
    private let logger: Logger

    public init() {
        self.init(timeZone: .current)
    }

    init(timeZone: TimeZone, logger: Logger = Logger(label: "frame-bridge.events")) {
        self.timeZone = timeZone
        self.logger = logger
    }

    var subscriberCount: Int { subscribers.count }

    func subscribe(bufferSize: Int = 16) -> (id: UUID, stream: AsyncStream<String>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(bufferSize))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        subscribers[id] = continuation
        return (id, stream)
    }

    func remove(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    func broadcast(_ message: String) {
        for (id, continuation) in subscribers {
            switch continuation.yield(message) {
            case .enqueued: break
            case .dropped:
                logger.info("events subscriber too slow, dropped")
                remove(id)
            case .terminated: remove(id)
            @unknown default: remove(id)
            }
        }
    }

    func send(_ event: ServerEvent) {
        do {
            broadcast(try event.encoded())
        } catch {
            logger.warning("events encode failed", metadata: ["event": .string(event.name)])
        }
    }

    func calendarChanged() { send(.calendar(.now(timeZone: timeZone))) }
    func shoppingChanged() { send(.shopping(.now(timeZone: timeZone))) }
    func weatherChanged() { send(.weather(.now(timeZone: timeZone))) }
    func photosChanged() { send(.photos(.now(timeZone: timeZone))) }
    func lightChanged(_ light: Light) { send(.light(light)) }
    func roomChanged(_ room: Room) { send(.room(room)) }
    func sceneChanged(_ scene: Scene) { send(.scene(scene)) }
    func lightsChanged() { send(.lights(.now(timeZone: timeZone))) }
    func nowPlayingChanged(_ value: NowPlaying) { send(.nowplaying(value)) }

    func ping() { broadcast(SSE.ping) }

    func finishAll() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
}
