import Foundation
import os
import TableProModels

// A library write this device made from a copy a sync pass has since moved, put on top of what the pass wrote. A record
// the write added or removed takes the write's side; one it changed keeps every field the write did not change as the
// pass wrote it, so an edit made on a stale copy never undoes what the pass brought, a stricter Safe Mode included. A
// record the write changed and the pass removed comes back, as a content edit revives a record deleted elsewhere (core
// ADR 0054, Rules for both providers). A change that cannot be merged keeps the pass's copy and is named, so the person
// is told it was not saved.
enum LibraryRebase {
    struct Rebased<Item: Identifiable> {
        var items: [Item]
        var unmerged: [Item.ID]
    }
    private static let logger = Logger(subsystem: "com.TablePro", category: "LibraryRebase")

    static func rebased<Item: Identifiable & Equatable & Codable>(
        _ written: [Item],
        from base: [Item],
        onto stored: [Item]
    ) -> Rebased<Item> where Item.ID: Hashable {
        let before = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(written.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = { (item: Item) in before[item.id] != item }
        var rebased: [Item] = []
        var unmerged: [Item.ID] = []
        for item in stored {
            guard let mine = after[item.id] else {
                // Removed by the write, or never in its copy.
                if before[item.id] == nil { rebased.append(item) }
                continue
            }
            guard changed(mine), let base = before[item.id] else {
                rebased.append(changed(mine) ? mine : item)
                continue
            }
            guard let merged = fields(of: mine, changedFrom: base, onto: item) else {
                unmerged.append(item.id)
                rebased.append(item)
                continue
            }
            rebased.append(merged)
        }
        let present = Set(rebased.map(\.id))
        rebased += written.filter { !present.contains($0.id) && changed($0) }
        return Rebased(items: rebased, unmerged: unmerged)
    }

    // The library to write, and the names of the records whose change did not merge.
    static func rebased(
        _ written: CoreLibraryStore.Library,
        from base: CoreLibraryStore.Library,
        onto stored: CoreLibraryStore.Library
    ) -> (library: CoreLibraryStore.Library, unmerged: [String]) {
        let connections = rebased(written.connections, from: base.connections, onto: stored.connections)
        let groups = rebased(written.groups, from: base.groups, onto: stored.groups)
        let tags = rebased(written.tags, from: base.tags, onto: stored.tags)
        let named = { (ids: [UUID], names: [UUID: String]) in ids.compactMap { names[$0] } }
        let unmerged = named(connections.unmerged, Dictionary(written.connections.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
            + named(groups.unmerged, Dictionary(written.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
            + named(tags.unmerged, Dictionary(written.tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
        return (
            CoreLibraryStore.Library(connections: connections.items, groups: groups.items, tags: tags.items),
            unmerged
        )
    }

    // The store's copy with each top-level member the write changed taken from the write. The library file's own
    // encoding, so a member only that file spells, an older build's SSL require among them, survives. Nil when the copies
    // do not encode or the merge does not decode.
    private static func fields<Item: Codable>(of mine: Item, changedFrom base: Item, onto theirs: Item) -> Item? {
        let encoder = JSONEncoder()
        encoder.userInfo[.deviceLibraryFile] = true
        func object(_ item: Item) -> NSDictionary? {
            (try? encoder.encode(item)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
        }
        guard let mineFields = object(mine), let baseFields = object(base),
              let merged = object(theirs)?.mutableCopy() as? NSMutableDictionary else {
            logger.error("A library edit made over a sync pass did not encode, so the pass's copy stands")
            return nil
        }
        let keys = Set(mineFields.allKeys.compactMap { $0 as? String }).union(baseFields.allKeys.compactMap { $0 as? String })
        for key in keys where !((mineFields[key] as AnyObject?)?.isEqual(baseFields[key]) ?? (baseFields[key] == nil)) {
            merged[key] = mineFields[key]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(Item.self, from: data) else {
            logger.error("A library edit made over a sync pass did not decode, so the pass's copy stands")
            return nil
        }
        return decoded
    }
}
