import Foundation
import Logging
import Testing

@testable import FrameBridgeCore

private actor Fetcher: ForecastFetching {
    var result: Result<Data, Error>
    init(_ r: Result<Data, Error>) { result = r }
    func set(_ r: Result<Data, Error>) { result = r }
    func fetchForecast() async throws -> Data { try result.get() }
}

private func drain(_ stream: AsyncStream<String>, after action: () async -> Void, hub: EventHub) async -> [String] {
    await action()
    await hub.finishAll()
    var out: [String] = []
    for await m in stream { out.append(m) }
    return out
}

@Test func weatherEventOnlyWhenForecastChanges() async throws {
    let hub = EventHub()
    let fetcher = Fetcher(.success(try WeatherFixture.data()))
    let store = WeatherStore(fetcher: fetcher, timeZone: TimeZone(identifier: "America/New_York")!, logger: Logger(label: "test"), events: hub)
    let (_, stream) = await hub.subscribe(bufferSize: 16)
    let got = await drain(stream, after: {
        await store.refresh()
        await store.refresh()
        await fetcher.set(.failure(ForecastFetchError.network(-1009)))
        await store.refresh()
    }, hub: hub)
    #expect(got.count == 1)
    #expect(got.first?.hasPrefix("event: weather\n") == true)
}
