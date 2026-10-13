import Foundation
import Logging

/// Where the reminders come from. The real one is EventKit; tests use a stub.
protocol ShoppingProvider: Sendable {
    func authorization() async -> FeedHealth.Authorization
    /// Why access can't be granted, when it can't be asked for (e.g. not run from the .app).
    func unavailableReason() async -> String?
    /// Incomplete reminders, plus those completed in [completedSince, until], in the list with this title.
    func reminders(listTitle: String, completedSince: Date, until: Date) async throws -> [ReminderValues]
}

extension ShoppingProvider {
    func unavailableReason() async -> String? { nil }
}

enum ShoppingSourceError: Error { case listNotFound }

/// Reads on demand, no cache: EventKit is the cache.
public actor ShoppingFeed {
    static let staleAfterSeconds = 300

    private let config: ShoppingConfig
    private let provider: any ShoppingProvider
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var lastSuccess: Date?
    private var lastError: String?
    private var lastNotified: ShoppingList?

    init(config: ShoppingConfig, provider: any ShoppingProvider, logger: Logger = Logger(label: "frame-bridge.shopping"), now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.provider = provider
        self.logger = logger
        self.now = now
    }

    func list() async throws(APIError) -> ShoppingList {
        do {
            let result = try await fetch()
            lastSuccess = now()
            lastError = nil
            return result
        } catch {
            lastError = error.detail
            throw error
        }
    }

    private func fetch() async throws(APIError) -> ShoppingList {
        guard await provider.authorization() == .fullAccess else {
            throw .sourceUnavailable("reminders access not granted")
        }
        let current = now()
        do {
            let values = try await provider.reminders(listTitle: config.list, completedSince: current.addingTimeInterval(-ItemMapping.completedWindow), until: current)
            return ItemMapping.list(values, config: config, now: current)
        } catch ShoppingSourceError.listNotFound {
            logger.warning("shopping list not found")
            throw .sourceUnavailable("list not found")
        } catch {
            logger.warning("reminders read failed")
            throw .sourceUnavailable("reminders read failed")
        }
    }

    /// Re-reads and reports whether the list differs from the last rebuild. The first call sets the
    /// baseline. Only this updates the baseline, so a GET in between can't swallow a change.
    func rebuild() async -> Bool {
        guard let current = try? await list() else { return false }
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
