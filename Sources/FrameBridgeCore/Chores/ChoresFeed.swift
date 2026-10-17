import Foundation
import Logging

/// Where the chore reminders come from. The real one is EventKit; tests use a stub.
protocol ChoresProvider: Sendable {
    func authorization() async -> FeedHealth.Authorization
    /// Why access can't be granted, when it can't be asked for (e.g. not run from the .app).
    func unavailableReason() async -> String?
    /// Incomplete reminders, plus those completed in [completedSince, until], in the list with this title.
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ChoreReminderValues]
    /// Check off or un-check one reminder, if it is in one of these lists. Nil when it isn't.
    /// `changed` is false when it already matched, and nothing is saved. For a recurring chore the
    /// returned values can be another reminder: the completed copy, or the restored original.
    func setDone(id: String, listTitles: [String], done: Bool, now: Date) async throws -> (values: ChoreReminderValues, listTitle: String, changed: Bool)?
}

extension ChoresProvider {
    func unavailableReason() async -> String? { nil }
}

enum ChoresSourceError: Error { case listNotFound }

/// Reads on demand, no cache: EventKit is the cache.
public actor ChoresFeed {
    static let staleAfterSeconds = 300

    private let config: ChoresConfig
    private let provider: any ChoresProvider
    private let logger: Logger
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var lastSuccess: Date?
    private var lastError: String?
    private var lastNotified: Snapshot?
    private var loggedUnexpanded: Set<String> = []

    private struct Snapshot: Equatable {
        var today: [Chore]
        var upcoming: [UpcomingChore]
    }

    init(config: ChoresConfig, provider: any ChoresProvider, logger: Logger = Logger(label: "frame-bridge.chores"), calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.provider = provider
        self.logger = logger
        self.calendar = calendar
        self.now = now
    }

    func list() async throws(APIError) -> ChoreList {
        let now = now()
        return ChoreList(chores: try await read { ChoreMapping.list(byPerson: $0, now: now, calendar: self.calendar) })
    }

    func upcoming() async throws(APIError) -> UpcomingChoreList {
        let result = try await read { ChoreMapping.upcoming(byPerson: $0, now: self.now(), calendar: self.calendar) }
        logUnexpanded(result.unexpanded)
        return UpcomingChoreList(chores: result.chores)
    }

    /// Reads every chore list once, maps it, and records success or failure for `/healthz`.
    private func read<T>(_ map: ([(who: String, reminders: [ChoreReminderValues])]) -> T) async throws(APIError) -> T {
        do {
            let result = map(try await fetch())
            lastSuccess = now()
            lastError = nil
            return result
        } catch {
            lastError = error.detail
            throw error
        }
    }

    private func fetch() async throws(APIError) -> [(who: String, reminders: [ChoreReminderValues])] {
        guard await provider.authorization() == .fullAccess else {
            throw .sourceUnavailable("reminders access not granted")
        }
        let current = now()
        let since = calendar.startOfDay(for: current)
        let until = calendar.date(byAdding: .day, value: 1, to: since) ?? current.addingTimeInterval(86400)
        do {
            var people: [(who: String, reminders: [ChoreReminderValues])] = []
            for ref in config.lists {
                people.append((ref.person, try await provider.reminders(listTitle: ref.list, completedSince: since, until: until)))
            }
            return people
        } catch ChoresSourceError.listNotFound {
            logger.warning("chore list not found")
            throw .sourceUnavailable("list not found")
        } catch {
            logger.warning("reminders read failed")
            throw .sourceUnavailable("reminders read failed")
        }
    }

    /// Warns once per reminder and reason. Never logs ids, titles or notes.
    private func logUnexpanded(_ items: [(id: String, reason: String)]) {
        for item in items where loggedUnexpanded.insert(item.id + "|" + item.reason).inserted {
            logger.warning("chore repeat rule not expanded", metadata: ["reason": "\(item.reason)"])
        }
    }

    /// Sets `done` on a reminder in a chore list and returns the chore as stored.
    func setDone(id: String, done: Bool) async throws(APIError) -> (chore: Chore, changed: Bool) {
        guard await provider.authorization() == .fullAccess else {
            throw .sourceUnavailable("reminders access not granted")
        }
        let result: (values: ChoreReminderValues, listTitle: String, changed: Bool)?
        do {
            result = try await provider.setDone(id: id, listTitles: config.lists.map(\.list), done: done, now: now())
        } catch ChoresSourceError.listNotFound {
            logger.warning("chore list not found")
            throw .sourceUnavailable("list not found")
        } catch {
            logger.warning("reminders write failed")
            throw .sourceUnavailable("reminders write failed")
        }
        guard let result, let ref = config.lists.first(where: { $0.list == result.listTitle }) else { throw .notFound }
        // Baseline now holds the write, so the EKEventStoreChanged rebuild that follows sends nothing.
        if result.changed { _ = await rebuild() }
        return (ChoreMapping.chore(result.values, who: ref.person, calendar: calendar), result.changed)
    }

    /// Re-reads and reports whether the chores differ from the last rebuild. The first call sets the
    /// baseline. Only this updates the baseline, so a GET in between can't swallow a change.
    func rebuild() async -> Bool {
        let now = now()
        guard let current = try? await read({ people in
            let upcoming = ChoreMapping.upcoming(byPerson: people, now: now, calendar: self.calendar)
            return (Snapshot(today: ChoreMapping.list(byPerson: people, now: now, calendar: self.calendar), upcoming: upcoming.chores), upcoming.unexpanded)
        }) else { return false }
        logUnexpanded(current.1)
        let snapshot = current.0
        defer { lastNotified = snapshot }
        guard let previous = lastNotified else { return false }
        return previous != snapshot
    }

    func startupCheck() async {
        _ = await rebuild()
    }

    func health() async -> FeedHealth {
        let auth = await provider.authorization()
        let updated = lastSuccess.map { WireDate.string(from: $0) }
        if auth != .fullAccess {
            let reason = await provider.unavailableReason() ?? "reminders access not granted"
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: reason, updatedAt: updated, authorization: auth)
        }
        if let lastError {
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: lastError, updatedAt: updated, authorization: auth)
        }
        return FeedHealth(status: .ok, staleAfterSeconds: Self.staleAfterSeconds, updatedAt: updated, authorization: auth)
    }
}
