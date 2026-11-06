import Foundation
import Logging
import ServiceLifecycle

/// Reads the Workers AI credentials after the server is listening, then runs the schedule until
/// shutdown. The Keychain read can wait on an "allow" prompt: until then only the summary answers
/// 503. Missing credentials don't stop the app.
struct SummaryService: Service {
    let feed: SummaryFeed
    let store: any WorkersAICredentialStore
    let events: EventHub
    let model: String
    let transport: any WorkersAITransport
    var timeZone: TimeZone = .current
    var logger = Logger(label: "frame-bridge.summary")

    func run() async throws {
        await cancelWhenGracefulShutdown { await loadAndRun() }
    }

    func loadAndRun() async {
        let credentials: WorkersAICredentials?
        do {
            credentials = try await Self.load(from: store)
        } catch is CancellationError {
            return
        } catch {
            credentials = nil
        }
        guard let credentials else {
            await feed.credentialsRead(nil)
            logger.warning("workers ai credentials not in the Keychain")
            try? await gracefulShutdown()
            return
        }
        await feed.credentialsRead(WorkersAIClient(accountId: credentials.accountId, token: credentials.token, model: model, transport: transport))
        logger.info("workers ai credentials read")
        await scheduleLoop()
    }

    func scheduleLoop() async {
        let wakeup = SummaryWakeup()
        await events.addChangeListener { await wakeup.changed(at: Date()) }
        var schedule = SummarySchedule(now: Date(), timeZone: timeZone)
        while !Task.isCancelled {
            let now = Date()
            if let change = await wakeup.takeChange() { schedule.changed(at: change, timeZone: timeZone) }
            switch schedule.nextAction(now: now, timeZone: timeZone) {
            case .generate:
                schedule.attemptStarted(at: now)
                await feed.generate(now: now)
            case .drop(let reason):
                schedule.dropped(now: now, timeZone: timeZone)
                await feed.drop(reason: reason)
            case .wait(let until):
                await wakeup.sleep(until: until)
            }
        }
    }

    /// `SecItemCopyMatching` can block on a prompt, so it runs off the cooperative pool.
    static func load(from store: any WorkersAICredentialStore) async throws -> WorkersAICredentials? {
        let once = ResumeOnce<WorkersAICredentials?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.start(continuation)
                DispatchQueue.global().async { once.resume(with: Result { try store.load() }) }
            }
        } onCancel: {
            once.resume(with: .failure(CancellationError()))
        }
    }
}

/// Wakes the schedule loop early on a change, and carries the change time to it.
actor SummaryWakeup {
    private var waiter: CheckedContinuation<Void, Never>?
    private var poked = false
    private var change: Date?

    func changed(at date: Date) {
        change = date
        poke()
    }

    func takeChange() -> Date? {
        defer { change = nil }
        return change
    }

    private func poke() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            poked = true
        }
    }

    /// Returns at `until`, on a change, or on cancellation.
    func sleep(until: Date) async {
        let timer = Task { [self] in
            // A cancelled sleep means the wait already ended.
            guard (try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))) != nil else { return }
            timerFired()
        }
        await withTaskCancellationHandler {
            await wait()
        } onCancel: {
            Task { await self.timerFired() }
        }
        timer.cancel()
    }

    private func timerFired() { poke() }

    private func wait() async {
        if poked {
            poked = false
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }
}
