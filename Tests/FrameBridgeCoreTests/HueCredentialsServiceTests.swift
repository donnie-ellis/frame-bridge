import Foundation
import Logging
import Testing

@testable import FrameBridgeCore

private let hue = HueConfig(bridge: "bridge.invalid", sceneIcons: HueFixture.icons)

/// A Keychain read that blocks, like one waiting on the "allow" prompt, until `answer` is called.
private final class BlockingStore: HueCredentialStore, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<HueCredentials?, any Error> = .success(nil)

    func answer(_ result: Result<HueCredentials?, any Error>) {
        lock.withLock { self.result = result }
        gate.signal()
    }

    func load() throws -> HueCredentials? {
        gate.wait()
        return try lock.withLock { result }.get()
    }

    func save(_ credentials: HueCredentials) throws {}
}

private struct Both: HueTransport, HueEventStreamTransport {
    let rest: FakeHueTransport
    let stream: FakeHueEventStream
    func send(method: String, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        try await rest.send(method: method, path: path, body: body)
    }
    func eventStream() async throws -> AsyncThrowingStream<Data, any Error> { try await stream.eventStream() }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Test func lightsSayTheyAreWaitingForTheKeychainUntilTheReadFinishes() async throws {
    let store = BlockingStore()
    let feed = LightsFeed(config: hue, client: nil, logger: Logger(label: "test"), readingCredentials: true)
    let both = Both(rest: FakeHueTransport(), stream: FakeHueEventStream([.open]))
    let service = HueCredentialsService(feed: feed, store: store, connect: { _ in both }, logger: Logger(label: "test"))
    let task = Task { await service.loadAndConnect() }

    #expect(await feed.health().detail == LightsFeed.waitingForKeychain)
    do {
        _ = try await feed.state()
        Issue.record("expected 503 while the Keychain read is pending")
    } catch {
        #expect(error.detail == LightsFeed.waitingForKeychain)
    }

    store.answer(.success(HueCredentials(applicationKey: "key", certificateSHA256: "pin")))
    #expect(await waitUntil { await feed.health().status == .ok })
    task.cancel()
    await task.value
}

@Test func noCredentialsMeansNotPaired() async throws {
    let store = BlockingStore()
    let feed = LightsFeed(config: hue, client: nil, logger: Logger(label: "test"), readingCredentials: true)
    let service = HueCredentialsService(feed: feed, store: store, connect: { _ in fatalError("no credentials, no transport") }, logger: Logger(label: "test"))
    let task = Task { await service.loadAndConnect() }
    store.answer(.success(nil))
    #expect(await waitUntil { await feed.health().detail == "not paired" })
    task.cancel()
    await task.value
}

@Test func shutdownDoesNotWaitForAnUnansweredPrompt() async throws {
    let store = BlockingStore()
    let task = Task { try await HueCredentialsService.load(from: store) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    store.answer(.success(nil))
}
