import Foundation
import Testing

@testable import FrameBridgeCore

private func nowPlaying(_ position: String, state: NowPlaying.State = .playing) throws -> (value: NowPlaying, artSource: ArtSource?) {
    let p = try SonosMapping.position(response: SonosFixture.data(position))
    return SonosMapping.nowPlaying(room: "Room A", state: state, trackURI: p.trackURI, didl: p.didl)
}

@Test func coordinatorOfUngroupedRoomIsItself() throws {
    let host = try SonosMapping.coordinatorHost(topologyResponse: SonosFixture.data("topology-alone"), room: "Room A")
    #expect(host == SonosFixture.hostA)
}

@Test func coordinatorOfGroupedRoomIsTheGroupCoordinator() throws {
    let host = try SonosMapping.coordinatorHost(topologyResponse: SonosFixture.data("topology-grouped"), room: "Room A")
    #expect(host == SonosFixture.hostB)
}

@Test func unknownRoomThrows() throws {
    #expect(throws: SonosError.roomNotFound) {
        try SonosMapping.coordinatorHost(topologyResponse: SonosFixture.data("topology-alone"), room: "Room Z")
    }
    #expect(throws: SonosError.badResponse) {
        try SonosMapping.coordinatorHost(topologyResponse: Data("not xml".utf8), room: "Room A")
    }
}

@Test func transportStatesMap() throws {
    let cases: [(String, NowPlaying.State)] = [("playing", .playing), ("paused", .paused), ("stopped", .stopped)]
    for (name, expected) in cases {
        let raw = try SonosMapping.transportState(response: SonosFixture.data("transport-\(name)"))
        #expect(SonosMapping.state(raw) == expected)
    }
    #expect(SonosMapping.state("NO_MEDIA_PRESENT") == .stopped)
}

@Test func transitioningKeepsThePreviousStateOrPlays() throws {
    let raw = try SonosMapping.transportState(response: SonosFixture.data("transport-transitioning"))
    #expect(raw == "TRANSITIONING")
    #expect(SonosMapping.state(raw, previous: .paused) == .paused)
    #expect(SonosMapping.state(raw) == .playing)
}

@Test func musicTrackMapsEveryField() throws {
    let result = try nowPlaying("position-music")
    #expect(result.value == NowPlaying(room: "Room A", state: .playing, title: "Example Song", artist: "Example Artist", album: "Example Album", art: true, source: .music))
    #expect(result.artSource == .speaker(path: "/getaa?s=1&u=x-sonos-spotify%3aexample"))
}

@Test func externalArtMeansNoArt() throws {
    let result = try nowPlaying("position-radio")
    #expect(result.value.art == false)
    #expect(result.artSource == nil)
    #expect(result.value.album == nil)
    #expect(result.value.source == .music)
}

@Test func tvAndLineInHaveNoTrackFields() throws {
    let tv = try nowPlaying("position-tv").value
    #expect(tv == NowPlaying(room: "Room A", state: .playing, source: .tv))
    let lineIn = try nowPlaying("position-linein").value
    #expect(lineIn == NowPlaying(room: "Room A", state: .playing, source: .lineIn))
}

@Test func emptyQueueOmitsSource() throws {
    let result = try nowPlaying("position-empty", state: .stopped)
    #expect(result.value == NowPlaying(room: "Room A", state: .stopped))
}

@Test func encodedValueHasNoNullsAndOmitsUnknowns() throws {
    for name in ["position-music", "position-radio", "position-radio-stream", "position-radio-talk", "position-tv", "position-linein", "position-empty"] {
        let text = String(decoding: try JSONEncoder().encode(nowPlaying(name).value), as: UTF8.self)
        #expect(!text.contains("null"))
    }
    let tv = String(decoding: try JSONEncoder().encode(nowPlaying("position-tv").value), as: UTF8.self)
    #expect(!tv.contains("title") && !tv.contains("art"))
    #expect(tv.contains(#""source":"tv""#))
}

@Test func noMetadataIsHandled() {
    let value = SonosMapping.nowPlaying(room: "Room A", state: .playing, trackURI: "x-file-cifs:example", didl: "NOT_IMPLEMENTED").value
    #expect(value == NowPlaying(room: "Room A", state: .playing, source: .music))
}

@Test func radioStreamContentGivesTrackFieldsAndExternalArt() throws {
    let result = try nowPlaying("position-radio-stream")
    #expect(result.value == NowPlaying(room: "Room A", state: .playing, title: "Radio Song", artist: "Radio Artist", album: "Radio Album", art: true, source: .music))
    #expect(result.artSource == .external(URL(string: "https://is1-ssl.mzstatic.com/image/thumb/example/1400x1400bb.jpg")!))
}

@Test func radioTalkWithoutTitleHasNoTrackFields() throws {
    let result = try nowPlaying("position-radio-talk")
    #expect(result.value.title == nil && result.value.artist == nil && result.value.album == nil)
    #expect(result.value.source == .music)
}

@Test func dcTitleWinsOverStreamContent() {
    let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:r=\"urn:r\"><item><dc:title>Real Title</dc:title><r:streamContent>TITLE Other</r:streamContent></item></DIDL-Lite>"
    let value = SonosMapping.nowPlaying(room: "Room A", state: .playing, trackURI: "x-sonosapi-stream:s1", didl: didl).value
    #expect(value.title == "Real Title")
}

@Test func allowedArtURLs() {
    for ok in ["https://is1-ssl.mzstatic.com/a.jpg", "https://mzstatic.com/a.jpg"] {
        #expect(ExternalArt.allowedURL(ok) != nil)
    }
    for bad in ["http://is1-ssl.mzstatic.com/a.jpg", "https://mzstatic.com.evil.invalid/a.jpg", "https://evilmzstatic.com/a.jpg",
                "https://mzstatic.com@evil.invalid/a.jpg", "https://example.com/a.jpg", "https://is1-ssl.mzstatic.com:8443/a.jpg", "/getaa?s=1"] {
        #expect(ExternalArt.allowedURL(bad) == nil)
    }
}
