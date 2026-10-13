import Foundation
import Testing

@testable import FrameBridgeCore

private func waitForCount(_ hub: EventHub, _ n: Int) async -> Bool {
    for _ in 0..<200 {
        if await hub.subscriberCount == n { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Test func bothSubscribersReceive() async {
    let hub = EventHub()
    let a = await hub.subscribe()
    let b = await hub.subscribe()
    await hub.broadcast("x")
    var ia = a.stream.makeAsyncIterator()
    var ib = b.stream.makeAsyncIterator()
    #expect(await ia.next() == "x")
    #expect(await ib.next() == "x")
}

@Test func removeAndTerminationDropCount() async {
    let hub = EventHub()
    let a = await hub.subscribe()
    var b: (id: UUID, stream: AsyncStream<String>)? = await hub.subscribe()
    #expect(await hub.subscriberCount == 2)
    await hub.remove(a.id)
    #expect(await hub.subscriberCount == 1)
    // Dropping the only consumer of the stream does not always terminate it, so cancel a reader.
    let reader = Task { [stream = b!.stream] in for await _ in stream {} }
    b = nil
    reader.cancel()
    #expect(await waitForCount(hub, 0))
}

@Test func fullBufferDropsOnlyTheStuckSubscriber() async {
    let hub = EventHub()
    let stuck = await hub.subscribe(bufferSize: 2)
    let live = await hub.subscribe(bufferSize: 2)
    var it = live.stream.makeAsyncIterator()
    for i in 0..<4 {
        await hub.broadcast("m\(i)")
        #expect(await it.next() == "m\(i)")
    }
    #expect(await hub.subscriberCount == 1)
    _ = stuck
}

@Test func finishAllEndsStreams() async {
    let hub = EventHub()
    let s = await hub.subscribe()
    await hub.finishAll()
    var it = s.stream.makeAsyncIterator()
    #expect(await it.next() == nil)
    #expect(await hub.subscriberCount == 0)
}
