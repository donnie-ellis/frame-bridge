import Foundation
import Logging

/// Today's summary, written by Workers AI in the background and cached. Every frame gets the same
/// text. It always matches the data: when a regeneration fails the old text is dropped, and it is
/// dropped at midnight. Event and chore text, the prompt and the reply are private: never log them.
public actor SummaryFeed {
    static let staleAfterSeconds = 86400

    private let calendar: CalendarFeed?
    private let chores: ChoresFeed?
    private let people: [Person]
    private let events: EventHub?
    private let timeZone: TimeZone
    private let logger: Logger
    private var generator: (any SummaryGenerating)?
    private var value: DaySummary?
    private var lastSuccess: Date?
    private var detail: String

    init(calendar: CalendarFeed?, chores: ChoresFeed?, people: [Person], events: EventHub? = nil, timeZone: TimeZone = .current, logger: Logger = Logger(label: "frame-bridge.summary")) {
        self.calendar = calendar
        self.chores = chores
        self.people = people
        self.events = events
        self.timeZone = timeZone
        self.logger = logger
        detail = calendar == nil && chores == nil ? "not configured" : "not generated yet"
    }

    /// Called once the Keychain has been read. Nil means the account id or token is missing.
    func credentialsRead(_ generator: (any SummaryGenerating)?) {
        self.generator = generator
        if generator == nil { detail = "not configured" } else if value == nil { detail = "not generated yet" }
    }

    /// Reads today's events and chores, asks the model, and stores the reply. Any failure drops the
    /// current summary. Only the schedule calls this, one run at a time: never a request handler.
    func generate(now: Date) async {
        guard let generator else { return }
        var calendarDay = Calendar(identifier: .gregorian)
        calendarDay.timeZone = timeZone
        let start = calendarDay.startOfDay(for: now)
        let end = calendarDay.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let todaysEvents: [Event]
        let todaysChores: [Chore]
        do {
            todaysEvents = try await calendar?.events(from: start, to: end) ?? []
            todaysChores = try await chores?.list().chores ?? []
        } catch {
            logger.warning("summary input unavailable", metadata: ["reason": .string(error.detail ?? "error")])
            await drop(reason: "calendar or chores unavailable")
            return
        }
        let prompt = SummaryPrompt.build(date: now, events: todaysEvents, chores: todaysChores, people: people, timeZone: timeZone)
        let text: String
        do {
            text = try await generator.generate(prompt)
        } catch is CancellationError {
            return
        } catch {
            let reason = Self.describe(error)
            logger.warning("summary generation failed", metadata: ["reason": .string(reason.log)])
            await drop(reason: reason.detail)
            return
        }
        let summary = DaySummary(date: SummaryDay.string(for: now, timeZone: timeZone), text: text)
        let changed = value != summary
        value = summary
        lastSuccess = now
        detail = ""
        logger.info("summary generated")
        if changed { await events?.summaryChanged() }
    }

    /// Clears the summary (midnight, the daily cap or a failure). One notice, and only if there was text.
    func drop(reason: String) async {
        detail = reason
        guard value != nil else { return }
        value = nil
        logger.info("summary dropped", metadata: ["reason": .string(reason)])
        await events?.summaryChanged()
    }

    private static func describe(_ error: Error) -> (detail: String, log: String) {
        switch error as? WorkersAIError {
        case .http(let status): ("Workers AI unreachable", "http \(status)")
        case .network(let code): ("Workers AI unreachable", "network \(code)")
        case .badResponse: ("reply rejected", "bad response")
        case .emptyReply: ("reply rejected", "empty reply")
        case .tooLong: ("reply rejected", "reply too long")
        case nil: ("Workers AI unreachable", "error")
        }
    }

    /// The cached summary, only while its date is today. Never generates.
    func current(now: Date = Date()) throws(APIError) -> DaySummary {
        guard let value, value.date == SummaryDay.string(for: now, timeZone: timeZone) else {
            throw .sourceUnavailable(value == nil ? detail : "not generated yet")
        }
        return value
    }

    func health(now: Date = Date()) -> FeedHealth {
        let updated = lastSuccess.map { WireDate.string(from: $0, timeZone: timeZone) }
        if value?.date == SummaryDay.string(for: now, timeZone: timeZone) {
            return FeedHealth(status: .ok, staleAfterSeconds: Self.staleAfterSeconds, updatedAt: updated)
        }
        return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: value == nil ? detail : "not generated yet", updatedAt: updated)
    }
}
