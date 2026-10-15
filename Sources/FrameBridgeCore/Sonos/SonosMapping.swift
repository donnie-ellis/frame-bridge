import Foundation

/// One element of a parsed document, in document order: `name` as written (`dc:title`).
struct XMLNode {
    let name: String
    let attributes: [String: String]
    var text: String
}

enum SimpleXML {
    private final class Collector: NSObject, XMLParserDelegate {
        var nodes: [XMLNode] = []
        var stack: [Int] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            nodes.append(XMLNode(name: elementName, attributes: attributeDict, text: ""))
            stack.append(nodes.count - 1)
        }

        // Delivered in chunks, so accumulate.
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let last = stack.last { nodes[last].text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let last = stack.last { nodes[last].text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }

    static func parse(_ data: Data) throws -> [XMLNode] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw SonosError.badResponse }
        return collector.nodes
    }
}

/// Speaker XML -> wire `NowPlaying`.
///
/// | Wire field | Source |
/// | --- | --- |
/// | `room` | the room name from config |
/// | `state` | GetTransportInfo `CurrentTransportState`: PLAYING, PAUSED_PLAYBACK, STOPPED / NO_MEDIA_PRESENT |
/// | `title` / `artist` / `album` | GetPositionInfo `TrackMetaData` DIDL: `dc:title`, `dc:creator`, `upnp:album` |
/// | `art` | `upnp:albumArtURI`: true for the speaker's own `/getaa`, false for any other URL, omitted if none |
/// | `source` | `TrackURI`: `x-sonos-htastream:` is tv, `x-rincon-stream:` is lineIn, empty is omitted, else music |
enum SonosMapping {
    /// The IP of the group coordinator for the member named `room`. The room may be grouped.
    static func coordinatorHost(topologyResponse: Data, room: String) throws -> String {
        let envelope = try SimpleXML.parse(topologyResponse)
        guard let state = envelope.first(where: { $0.name == "ZoneGroupState" })?.text else { throw SonosError.badResponse }
        let nodes = try SimpleXML.parse(Data(state.utf8))
        var coordinator: String?
        var members: [(group: String?, uuid: String, location: String, name: String)] = []
        var group: String?
        for node in nodes {
            if node.name == "ZoneGroup" { group = node.attributes["Coordinator"] }
            if node.name == "ZoneGroupMember", let uuid = node.attributes["UUID"] {
                members.append((group, uuid, node.attributes["Location"] ?? "", node.attributes["ZoneName"] ?? ""))
            }
        }
        coordinator = members.first { $0.name == room }?.group
        guard let coordinator, let member = members.first(where: { $0.uuid == coordinator }),
              let host = URL(string: member.location)?.host, !host.isEmpty
        else { throw SonosError.roomNotFound }
        return host
    }

    static func transportState(response: Data) throws -> String {
        guard let text = try SimpleXML.parse(response).first(where: { $0.name == "CurrentTransportState" })?.text else { throw SonosError.badResponse }
        return text
    }

    /// TRANSITIONING is brief, so it keeps the last state (or playing on a first read).
    static func state(_ transportState: String, previous: NowPlaying.State? = nil) -> NowPlaying.State {
        switch transportState {
        case "PLAYING": .playing
        case "PAUSED_PLAYBACK": .paused
        case "TRANSITIONING": previous ?? .playing
        default: .stopped
        }
    }

    static func position(response: Data) throws -> (trackURI: String, didl: String) {
        let nodes = try SimpleXML.parse(response)
        guard nodes.contains(where: { $0.name == "TrackURI" || $0.name == "TrackMetaData" }) else { throw SonosError.badResponse }
        return (nodes.first { $0.name == "TrackURI" }?.text ?? "", nodes.first { $0.name == "TrackMetaData" }?.text ?? "")
    }

    static func nowPlaying(room: String, state: NowPlaying.State, trackURI: String, didl: String) -> (value: NowPlaying, artPath: String?) {
        var value = NowPlaying(room: room, state: state)
        if trackURI.hasPrefix("x-sonos-htastream:") {
            value.source = .tv
            return (value, nil)
        }
        if trackURI.hasPrefix("x-rincon-stream:") {
            value.source = .lineIn
            return (value, nil)
        }
        if !trackURI.isEmpty { value.source = .music }
        var artPath: String?
        if !didl.isEmpty, didl != "NOT_IMPLEMENTED", let nodes = try? SimpleXML.parse(Data(didl.utf8)) {
            func text(_ name: String) -> String? {
                let trimmed = nodes.first { $0.name == name }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            value.title = text("dc:title")
            value.artist = text("dc:creator")
            value.album = text("upnp:album")
            if let art = text("upnp:albumArtURI") {
                value.art = art.hasPrefix(SonosClient.artPrefix)
                if value.art == true { artPath = art }
            }
        }
        return (value, artPath)
    }
}
