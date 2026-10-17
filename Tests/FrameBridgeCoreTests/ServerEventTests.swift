import Foundation
import Testing

@testable import FrameBridgeCore

private let ny = TimeZone(identifier: "America/New_York")!

@Test func shoppingNoticeMatchesSpec() throws {
    let date = Date(timeIntervalSince1970: 1791839051) // 2026-10-12T21:04:11Z
    let notice = ChangeNotice(changedAt: WireDate.string(from: date, timeZone: ny))
    #expect(try ServerEvent.shopping(notice).encoded() == "event: shopping\ndata: {\"changedAt\":\"2026-10-12T17:04:11-04:00\"}\n\n")
}

@Test func lightMatchesSpecExample() throws {
    let light = Light(id: "6d2b7c11-0000-4000-8000-000000000001", room: "0f6c1a9e-0000-4000-8000-00000000000a", name: "Pendants", on: false, level: 80)
    let text = try ServerEvent.light(light).encoded()
    let json = #"{"id":"6d2b7c11-0000-4000-8000-000000000001","room":"0f6c1a9e-0000-4000-8000-00000000000a","type":"light","name":"Pendants","on":false,"level":80}"#
    let decoded = try JSONDecoder().decode(Light.self, from: Data(json.utf8))
    #expect(decoded == light)
    #expect(text.hasPrefix("event: light\ndata: {"))
    #expect(text.contains(#""type":"light""#))
    #expect(text.hasSuffix("}\n\n"))
}

@Test func namesAndShape() throws {
    let n = ChangeNotice.now(timeZone: ny)
    let events: [(ServerEvent, String)] = [(.calendar(n), "calendar"), (.shopping(n), "shopping"), (.chores(n), "chores"), (.weather(n), "weather"), (.photos(n), "photos"),
        (.light(Light(id: "a", room: "b", name: "c", on: true, level: 1)), "light"),
        (.room(Room(id: "r", name: "n", kind: .room, on: true, level: 5, lights: ["a"])), "room"),
        (.scene(Scene(id: "s", room: "r", name: "n", active: false)), "scene"),
        (.lights(n), "lights"),
        (.nowplaying(NowPlaying(room: "Kitchen", state: .playing, source: .tv)), "nowplaying")]
    for (event, name) in events {
        let text = try event.encoded()
        #expect(text.hasPrefix("event: \(name)\ndata: "))
        #expect(!text.contains("null"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4) // event, data, two empty from the blank line end
        #expect(!text.contains("-04:00Z") && !n.changedAt.hasSuffix("Z"))
    }
}

@Test func constants() {
    #expect(SSE.retry == "retry: 5000\n\n")
    #expect(SSE.ping == ": ping\n\n")
}

@Test func nowPlayingMatchesSpecExample() throws {
    let value = NowPlaying(room: "Kitchen", state: .playing, title: "Example Song", artist: "Example Artist", album: "Example Album", art: true, source: .music)
    let text = try ServerEvent.nowplaying(value).encoded()
    #expect(text.hasPrefix("event: nowplaying\ndata: {"))
    let data = Data(text.split(separator: "\n")[1].dropFirst("data: ".count).utf8)
    #expect(try JSONDecoder().decode(NowPlaying.self, from: data) == value)
    #expect(text.contains(#""source":"music""#))
    let tv = try ServerEvent.nowplaying(NowPlaying(room: "Kitchen", state: .playing, source: .tv)).encoded()
    #expect(tv.contains(#""source":"tv""#) && !tv.contains("title") && !tv.contains("art"))
}
