import Foundation

/// Merges the bridge's event batches into the cached `HueResources`.
///
/// | Hue update field        | HueResources field                                   |
/// |-------------------------|------------------------------------------------------|
/// | light `on.on`           | `HueLight.on`                                        |
/// | light `dimming`         | `HueLight.dimming` (kept when only `on` changes)     |
/// | grouped_light `on`, `dimming` | `HueGroupedLight.on`, `.dimming`               |
/// | room, zone, light, scene `metadata.name` | the same resource's `metadata`      |
/// | scene `status.active`   | `HueScene.status`                                    |
///
/// A resync (one full read) is needed for an add or delete of a mapped type, for an update to an
/// id the cache doesn't know, and for an update that changes `owner`, `children`, `services` or
/// `group`. Bridge events repeat unchanged `owner` and `group`, so those only count when they
/// differ. `error` batches and other types (motion, zigbee_connectivity, ...) are ignored.
enum HueEventMerge {
    private static let mapped: Set<String> = ["light", "device", "room", "zone", "grouped_light", "scene"]

    /// Returns true when the cache can't follow the events and needs a full read.
    static func apply(_ batches: [HueEventBatch], to r: inout HueResources) -> Bool {
        var needsResync = false
        for batch in batches {
            for item in batch.resources where mapped.contains(item.type) {
                switch batch.kind {
                case .add, .delete: needsResync = true
                case .update: if !update(item, in: &r) { needsResync = true }
                case .error: break
                }
            }
        }
        return needsResync
    }

    /// False when the resource is unknown or its structure changed.
    private static func update(_ item: HueEventResource, in r: inout HueResources) -> Bool {
        switch item.type {
        case "light":
            guard let i = r.lights.firstIndex(where: { $0.id == item.id }) else { return false }
            if let on = item.on { r.lights[i].on = HueLight.On(on: on) }
            if let b = item.brightness { r.lights[i].dimming = HueLight.Dimming(brightness: b) }
            if let name = item.name { r.lights[i].metadata = HueMetadata(name: name) }
            return item.owner.map { $0 == r.lights[i].owner } ?? true
        case "grouped_light":
            guard let i = r.groupedLights.firstIndex(where: { $0.id == item.id }) else { return false }
            if let on = item.on { r.groupedLights[i].on = HueLight.On(on: on) }
            if let b = item.brightness { r.groupedLights[i].dimming = HueLight.Dimming(brightness: b) }
            return true
        case "room", "zone":
            let isRoom = item.type == "room"
            guard let i = (isRoom ? r.rooms : r.zones).firstIndex(where: { $0.id == item.id }) else { return false }
            var group = isRoom ? r.rooms[i] : r.zones[i]
            if let name = item.name { group.metadata = HueMetadata(name: name) }
            let same = (item.children.map { $0 == group.children } ?? true) && (item.services.map { $0 == group.services } ?? true)
            if isRoom { r.rooms[i] = group } else { r.zones[i] = group }
            return same
        case "scene":
            guard let i = r.scenes.firstIndex(where: { $0.id == item.id }) else { return false }
            if let name = item.name { r.scenes[i].metadata = HueMetadata(name: name) }
            if let active = item.active { r.scenes[i].status = HueScene.Status(active: active) }
            return item.group.map { $0 == r.scenes[i].group } ?? true
        default: // device
            guard let device = r.devices.first(where: { $0.id == item.id }) else { return false }
            return item.services.map { $0 == device.services } ?? true
        }
    }

    /// New or changed lights, then rooms, then scenes, in the bridge's order. Removals send nothing.
    static func events(from old: LightsState, to new: LightsState) -> [ServerEvent] {
        func changed<T: Identifiable & Equatable>(_ before: [T], _ after: [T]) -> [T] where T.ID == String {
            let known = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return after.filter { known[$0.id] != $0 }
        }
        return changed(old.devices, new.devices).map { ServerEvent.light($0) }
            + changed(old.rooms, new.rooms).map { ServerEvent.room($0) }
            + changed(old.scenes, new.scenes).map { ServerEvent.scene($0) }
    }

    /// True when a light, room/zone or scene was added or removed: the set of ids decides the `lights` notice.
    static func idsChanged(_ old: LightsState, _ new: LightsState) -> Bool {
        Set(old.devices.map(\.id)) != Set(new.devices.map(\.id))
            || Set(old.rooms.map(\.id)) != Set(new.rooms.map(\.id))
            || Set(old.scenes.map(\.id)) != Set(new.scenes.map(\.id))
    }
}

extension Light: Identifiable {}
extension Room: Identifiable {}
extension Scene: Identifiable {}
