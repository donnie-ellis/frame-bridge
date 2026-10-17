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
    private var lastNotified: [Chore]?

    init(config: ChoresConfig, provider: any ChoresProvider, logger: Logger = Logger(label: "frame-bridge.chores"), calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.provider = provider
        self.logger = logger
        self.calendar = calendar
        self.now = now
    }

    func list() async throws(APIError) -> ChoreList {
        do {
            let result = try await fetch()
            lastSuccess = now()
            lastError = nil
            return ChoreList(chores: result)
        } catch {
            lastError = error.detail
            throw error
        }
    }

    private func fetch() async throws(APIError) -> [Chore] {
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
            return ChoreMapping.list(byPerson: people, now: current, calendar: calendar)
        } catch ChoresSourceError.listNotFound {
            logger.warning("chore list not found")
            throw .sourceUnavailable("list not found")
        } catch {
            logger.warning("reminders read failed")
            throw .sourceUnavailable("reminders read failed")
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
        guard let current = try? await list().chores else { return false }
        defer { lastNotified = current }
        guard let previous = lastNotified else { return false }
        return previous != current
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
