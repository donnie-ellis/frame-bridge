import Foundation
import Logging

/// Where the occurrences come from. The real one is EventKit; tests use a stub.
protocol CalendarProvider: Sendable {
    func authorization() async -> FeedHealth.Authorization
    /// Occurrences overlapping [from, to) on the calendars with these titles.
    func events(from: Date, to: Date, calendarTitles: Set<String>) async throws -> [EventValues]
    /// Why access can't be granted, when it can't be asked for (e.g. not run from the .app).
    func unavailableReason() async -> String?
}

extension CalendarProvider {
    func unavailableReason() async -> String? { nil }
}

/// Reads on demand, no cache: EventKit is the cache.
public actor CalendarFeed {
    static let staleAfterSeconds = 900

    private let config: CalendarConfig
    private let provider: any CalendarProvider
    private let timeZone: TimeZone
    private let logger: Logger
    private var lastSuccess: Date?
    private var lastError: String?

    init(config: CalendarConfig, provider: any CalendarProvider, timeZone: TimeZone = .current, logger: Logger = Logger(label: "frame-bridge.calendar")) {
        self.config = config
        self.provider = provider
        self.timeZone = timeZone
        self.logger = logger
    }

    func events(from: Date, to: Date) async throws(APIError) -> [Event] {
        guard await provider.authorization() == .fullAccess else {
            throw .sourceUnavailable("calendar access not granted")
        }
        do {
            let values = try await provider.events(from: from, to: to, calendarTitles: Set(config.calendars.keys))
            let result = EventMapping.eventsInRange(values, config: config, from: from, to: to, timeZone: timeZone)
            lastSuccess = Date()
            lastError = nil
            return result
        } catch {
            lastError = "calendar read failed"
            logger.warning("calendar read failed")
            throw .sourceUnavailable("calendar read failed")
        }
    }

    /// One read for today, so /healthz is meaningful before the first request.
    func startupCheck() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        _ = try? await events(from: start, to: end)
    }

    func health() async -> FeedHealth {
        let auth = await provider.authorization()
        let updated = lastSuccess.map { WireDate.string(from: $0, timeZone: timeZone) }
        if auth != .fullAccess {
            let reason = await provider.unavailableReason() ?? "calendar access not granted"
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: reason, updatedAt: updated, authorization: auth)
        }
        if let lastError {
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: lastError, updatedAt: updated, authorization: auth)
        }
        return FeedHealth(status: .ok, staleAfterSeconds: Self.staleAfterSeconds, updatedAt: updated, authorization: auth)
    }
}
