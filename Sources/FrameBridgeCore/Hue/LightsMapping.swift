import Foundation

/// Hue CLIP v2 -> `LightsState` and `Light`.
///
/// | Wire                  | Hue                                                                     |
/// |-----------------------|-------------------------------------------------------------------------|
/// | Light.id, name        | light `id`, `metadata.name`                                             |
/// | Light.on              | light `on.on`                                                           |
/// | Light.level           | light `dimming.brightness` rounded, at least 1; 100 without dimming    |
/// | Light.room            | the kept room whose `children` has the light's owner device             |
/// | Room.id, name, kind   | room or zone `id`, `metadata.name`; `room` or `zone`                    |
/// | Room.on, level        | the `grouped_light` in its `services`; same level rule                  |
/// | Room.lights           | room: children devices -> their light services; zone: children lights   |
/// | Scene.room            | scene `group.rid`                                                       |
/// | Scene.active          | `status.active` isn't `inactive` (no status: false)                     |
/// | setRoom              | one `grouped_light` PUT, then a re-read of it for the response          |
/// | recallScene          | one `scene` PUT; the response is the snapshot's Scene with active true  |
/// | Scene.icon            | the config's scene name -> icon map; omitted when not mapped            |
///
/// Rooms and zones without a `grouped_light` are left out, with their scenes. Lights in no kept
/// room are left out of `devices` and of every `Room.lights`. The bridge's order is kept.
enum LightsMapping {
    static func level(_ brightness: Double?) -> Int {
        guard let brightness else { return 100 }
        return min(100, max(1, Int(brightness.rounded(.toNearestOrAwayFromZero))))
    }

    static func light(_ l: HueLight, room: String) -> Light {
        Light(id: l.id, room: room, name: l.metadata.name, on: l.on.on, level: level(l.dimming?.brightness))
    }

    static func state(_ r: HueResources, sceneIcons: [String: String]) -> LightsState {
        let grouped = Dictionary(r.groupedLights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lightsByID = Dictionary(r.lights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let devices = Dictionary(r.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func groupedLight(for group: HueGroup) -> HueGroupedLight? {
            group.services.first { $0.rtype == "grouped_light" }.flatMap { grouped[$0.rid] }
        }

        // Light id -> room id, through the owner device.
        var roomOfDevice: [String: String] = [:]
        var kept: [(group: HueGroup, kind: Room.Kind, grouped: HueGroupedLight)] = []
        for (group, kind) in r.rooms.map({ ($0, Room.Kind.room) }) + r.zones.map({ ($0, Room.Kind.zone) }) {
            guard let g = groupedLight(for: group) else { continue }
            kept.append((group, kind, g))
            if kind == .room {
                for child in group.children where child.rtype == "device" { roomOfDevice[child.rid] = roomOfDevice[child.rid] ?? group.id }
            }
        }

        let devicesOut: [Light] = r.lights.compactMap { l in
            roomOfDevice[l.owner.rid].map { light(l, room: $0) }
        }
        let keptLightIDs = Set(devicesOut.map(\.id))

        let rooms: [Room] = kept.map { entry in
            var ids: [String] = []
            switch entry.kind {
            case .room:
                for child in entry.group.children where child.rtype == "device" {
                    guard let device = devices[child.rid] else { continue }
                    ids += device.services.filter { $0.rtype == "light" }.map(\.rid)
                }
            case .zone:
                ids = entry.group.children.filter { $0.rtype == "light" }.map(\.rid)
            }
            ids = ids.filter { keptLightIDs.contains($0) && lightsByID[$0] != nil }
            return Room(id: entry.group.id, name: entry.group.metadata.name, kind: entry.kind,
                        on: entry.grouped.on?.on ?? false, level: level(entry.grouped.dimming?.brightness), lights: ids)
        }

        let keptIDs = Set(rooms.map(\.id))
        let scenes: [Scene] = r.scenes.compactMap { s in
            guard keptIDs.contains(s.group.rid) else { return nil }
            return Scene(id: s.id, room: s.group.rid, name: s.metadata.name, active: s.status.map { $0.active != "inactive" } ?? false, icon: sceneIcons[s.metadata.name])
        }
        return LightsState(rooms: rooms, devices: devicesOut, scenes: scenes)
    }

    /// The `grouped_light` id of a kept room or zone; nil when it has none, or the id is unknown.
    static func groupedLightID(ofGroup id: String, in r: HueResources) -> String? {
        guard let group = (r.rooms + r.zones).first(where: { $0.id == id }),
              let rid = group.services.first(where: { $0.rtype == "grouped_light" })?.rid,
              r.groupedLights.contains(where: { $0.id == rid })
        else { return nil }
        return rid
    }

    static func room(_ room: Room, after grouped: HueGroupedLight) -> Room {
        var updated = room
        updated.on = grouped.on?.on ?? false
        updated.level = level(grouped.dimming?.brightness)
        return updated
    }

    static let recallBody = Data(#"{"recall":{"action":"active"}}"#.utf8)

    /// The Hue PUT body. A level on a light that's off turns it on.
    static func hueBody(for patch: LightPatch, dimmable: Bool) -> Data {
        var body: [String: Any] = [:]
        if let on = patch.on {
            body["on"] = ["on": on]
        } else if patch.level != nil {
            body["on"] = ["on": true]
        }
        if let level = patch.level, dimmable {
            body["dimming"] = ["brightness": level]
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
