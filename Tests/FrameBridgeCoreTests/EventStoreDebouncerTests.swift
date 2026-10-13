import Foundation
import Testing

@testable import FrameBridgeCore

private actor Counter {
    var n = 0
    func bump() { n += 1 }
}

@Test func burstCallsEachSubscriberOnce() async throws {
    let d = EventStoreDebouncer(interval: .milliseconds(50))
    let a = Counter(), b = Counter()
    await d.subscribe { await a.bump() }
    await d.subscribe { await b.bump() }
    for _ in 0..<5 {
        await d.poke()
        try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(250))
    let (na, nb) = (await a.n, await b.n)
    #expect(na == 1 && nb == 1)
    await d.poke()
    try await Task.sleep(for: .milliseconds(250))
    let again = await a.n
    #expect(again == 2)
}

@Test func burstSendsOneCalendarNoticeThroughTheHub() async throws {
    let hub = EventHub()
    let d = EventStoreDebouncer(interval: .milliseconds(50))
    await d.subscribe { await hub.calendarChanged() }
    let (_, stream) = await hub.subscribe()
    for _ in 0..<5 { await d.poke() }
    try await Task.sleep(for: .milliseconds(250))
    await hub.finishAll()
    var messages: [String] = []
    for await m in stream { messages.append(m) }
    #expect(messages.count == 1)
    #expect(messages.first?.contains("event: calendar") == true)
}
