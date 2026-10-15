import Foundation

/// Opens the bridge's `/eventstream/clip/v2`. Each element is a chunk of the raw SSE bytes.
protocol HueEventStreamTransport: Sendable {
    func eventStream() async throws -> AsyncThrowingStream<Data, any Error>
}

/// Splits raw SSE bytes into messages. A blank line ends a message, several `data:` lines join
/// with a newline, `\r\n` works, and `id:` lines and comments are ignored.
struct HueEventStreamParser {
    private var buffer = Data()
    private var dataLines: [String] = []

    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var messages: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[(newline + 1)...])
            if line.last == 0x0D { line = line.dropLast() }
            let text = String(decoding: line, as: UTF8.self)
            if text.isEmpty {
                if !dataLines.isEmpty {
                    messages.append(dataLines.joined(separator: "\n"))
                    dataLines = []
                }
            } else if text.hasPrefix("data:") {
                var value = text.dropFirst(5)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                dataLines.append(String(value))
            }
        }
        return messages
    }
}

/// One item of a batch's `data`, only the fields the merge reads.
struct HueEventResource: Equatable, Sendable {
    var id: String
    var type: String
    var on: Bool?
    var brightness: Double?
    var name: String?
    var active: String?
    var owner: HueRef?
    var children: [HueRef]?
    var services: [HueRef]?
    var group: HueRef?
}

struct HueEventBatch: Equatable, Sendable {
    enum Kind: String, Sendable { case update, add, delete, error }
    var kind: Kind
    var resources: [HueEventResource]
}

enum HueEventDecoder {
    /// A message is a JSON array of batches. A batch or item of an unknown shape is skipped.
    static func batches(in message: String) -> [HueEventBatch] {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [Any] else { return [] }
        return array.compactMap { element in
            guard let batch = element as? [String: Any],
                  let kind = (batch["type"] as? String).flatMap(HueEventBatch.Kind.init(rawValue:)),
                  let items = batch["data"] as? [Any]
            else { return nil }
            return HueEventBatch(kind: kind, resources: items.compactMap { resource($0 as? [String: Any]) })
        }
    }

    private static func resource(_ item: [String: Any]?) -> HueEventResource? {
        guard let item, let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        return HueEventResource(
            id: id, type: type,
            on: (item["on"] as? [String: Any])?["on"] as? Bool,
            brightness: ((item["dimming"] as? [String: Any])?["brightness"] as? NSNumber)?.doubleValue,
            name: (item["metadata"] as? [String: Any])?["name"] as? String,
            active: (item["status"] as? [String: Any])?["active"] as? String,
            owner: ref(item["owner"]), children: refs(item["children"]), services: refs(item["services"]), group: ref(item["group"])
        )
    }

    private static func ref(_ value: Any?) -> HueRef? {
        guard let dict = value as? [String: Any], let rid = dict["rid"] as? String, let rtype = dict["rtype"] as? String else { return nil }
        return HueRef(rid: rid, rtype: rtype)
    }

    private static func refs(_ value: Any?) -> [HueRef]? {
        (value as? [Any])?.compactMap { ref($0) }
    }
}
