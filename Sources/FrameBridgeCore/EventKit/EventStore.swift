import EventKit
import Foundation
import Logging
import ServiceLifecycle

/// The one `EKEventStore` for calendar, shopping and chores. Calendar is read only. The writes are
/// `EventKitShoppingSource.setCompleted` and `EventKitChoresSource.setDone` (isCompleted plus
/// save(_:commit: true)). The one exception, owner-approved in #60: undoing a recurring chore
/// restores the original's due date and removes the completed copy (`ChoreUndo`), in a chore list
/// only. Nothing else calls remove or a bare commit().
// @unchecked: EKEventStore is documented as usable from any thread for reads, and `denied` is only
// written once, before the observer starts.
final class SharedEventStore: @unchecked Sendable {
    let store = EKEventStore()
    private let logger: Logger
    private let lock = NSLock()
    private var _unavailableReason: String?

    init(logger: Logger = Logger(label: "frame-bridge.eventkit")) {
        self.logger = logger
    }

    var unavailableReason: String? { lock.withLock { _unavailableReason } }

    /// Asking for access from a binary without the privacy string kills the process, so `swift run`
    /// skips it. The .app bundle has the string.
    func requestEventsAccess() async {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else {
            lock.withLock { _unavailableReason = "not running from the .app bundle" }
            logger.warning("not running from the .app bundle, skipping the calendar access request")
            return
        }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            logger.warning("calendar access request failed")
        }
    }

    /// Same bundle guard as events: the privacy string must be in the .app's Info.plist.
    func requestRemindersAccess() async {
        guard Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil else {
            lock.withLock { _unavailableReason = "not running from the .app bundle" }
            logger.warning("not running from the .app bundle, skipping the reminders access request")
            return
        }
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            logger.warning("reminders access request failed")
        }
    }

    static func authorization(for type: EKEntityType) -> FeedHealth.Authorization {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        case .authorized: .fullAccess
        @unknown default: .notDetermined
        }
    }
}

/// EKEventStoreChanged fires in bursts: waits for a quiet interval, then calls each subscriber once.
actor EventStoreDebouncer {
    private let interval: Duration
    private var handlers: [@Sendable () async -> Void] = []
    private var pending: Task<Void, Never>?

    init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    func subscribe(_ handler: @escaping @Sendable () async -> Void) {
        handlers.append(handler)
    }

    func poke() {
        pending?.cancel()
        pending = Task { [interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    private func fire() async {
        pending = nil
        for handler in handlers { await handler() }
    }

    func stop() {
        pending?.cancel()
        pending = nil
    }
}

/// Requests access, checks each feed once, then forwards store changes to the debouncer until shutdown.
struct EventStoreService: Service {
    let store: SharedEventStore
    let debouncer: EventStoreDebouncer
    let calendar: CalendarFeed?
    let shopping: ShoppingFeed?
    let chores: ChoresFeed?
    let events: EventHub

    func run() async throws {
        if let calendar {
            let events = events
            await debouncer.subscribe { await events.calendarChanged() }
            await store.requestEventsAccess()
            await calendar.startupCheck()
        }
        if let shopping {
            let events = events
            await debouncer.subscribe { if await shopping.rebuild() { await events.shoppingChanged() } }
        }
        if let chores {
            let events = events
            await debouncer.subscribe { if await chores.rebuild() { await events.choresChanged() } }
        }
        if shopping != nil || chores != nil { await store.requestRemindersAccess() }
        await shopping?.startupCheck()
        await chores?.startupCheck()
        let debouncer = debouncer
        let observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store.store, queue: nil) { _ in
            Task { await debouncer.poke() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try? await gracefulShutdown()
        await debouncer.stop()
    }
}
