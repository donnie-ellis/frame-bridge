import Foundation
import Logging
import os
import ServiceLifecycle

/// Reads the Hue credentials after the server is listening, then keeps the event stream open.
/// The Keychain read can wait on an "allow" prompt on the Mac's screen for as long as nobody
/// answers it: until then only the lights routes answer 503, the rest of the bridge is unaffected.
struct HueCredentialsService: Service {
    let feed: LightsFeed
    let store: any HueCredentialStore
    let connect: @Sendable (HueCredentials) -> any HueTransport & HueEventStreamTransport
    var logger = Logger(label: "frame-bridge.lights")

    func run() async throws {
        await cancelWhenGracefulShutdown { await loadAndConnect() }
    }

    func loadAndConnect() async {
        logger.info("reading hue credentials from the Keychain")
        let credentials: HueCredentials?
        do {
            credentials = try await Self.load(from: store)
        } catch is CancellationError {
            return
        } catch {
            logger.warning("hue credentials could not be read from the Keychain")
            credentials = nil
        }
        guard let credentials else {
            await feed.credentialsRead(nil)
            logger.warning("hue not paired: run FrameBridge hue-pair <bridge ip>")
            try? await gracefulShutdown()
            return
        }
        let transport = connect(credentials)
        await feed.credentialsRead(HueClient(transport: transport))
        logger.info("hue credentials read")
        await LightsService(feed: feed, transport: transport, logger: logger).connectLoop()
    }

    /// `SecItemCopyMatching` blocks until the prompt is answered, so it runs on its own queue, off
    /// the cooperative pool. Shutdown doesn't wait for it: the late answer is dropped.
    static func load(from store: any HueCredentialStore) async throws -> HueCredentials? {
        let once = ResumeOnce<HueCredentials?>()
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

/// Resumes a continuation at most once, whichever comes first. A cancellation that arrives before
/// `start` resumes it as soon as it starts.
final class ResumeOnce<T: Sendable>: Sendable {
    private enum State: Sendable {
        case waiting(CheckedContinuation<T, any Error>?)
        case cancelled
        case done
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .waiting(nil))

    func start(_ continuation: CheckedContinuation<T, any Error>) {
        let cancelled = state.withLock { state in
            if case .cancelled = state { state = .done; return true }
            state = .waiting(continuation)
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func resume(with result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>? = state.withLock { state in
            guard case .waiting(let continuation) = state else { return nil }
            if continuation == nil {
                if case .failure(let error) = result, error is CancellationError { state = .cancelled }
                return nil
            }
            state = .done
            return continuation
        }
        continuation?.resume(with: result)
    }
}
