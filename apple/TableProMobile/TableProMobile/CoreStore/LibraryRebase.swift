import Foundation

// A library write this device made from a copy a sync pass has since moved, put on top of what the pass wrote: each
// record the write added, changed or removed takes the write's side, and every other record the store's. A record the
// write changed and the pass removed comes back, as a content edit revives a record deleted elsewhere (core ADR 0054,
// Rules for both providers).
enum LibraryRebase {
    static func rebased<Item: Identifiable & Equatable>(_ written: [Item], from base: [Item], onto stored: [Item]) -> [Item]
    where Item.ID: Hashable {
        let before = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(written.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = { (item: Item) in before[item.id] != item }
        var rebased: [Item] = []
        for item in stored {
            guard let mine = after[item.id] else {
                // Removed by the write, or never in its copy.
                if before[item.id] == nil { rebased.append(item) }
                continue
            }
            rebased.append(changed(mine) ? mine : item)
        }
        let present = Set(rebased.map(\.id))
        rebased += written.filter { !present.contains($0.id) && changed($0) }
        return rebased
    }

    static func rebased(
        _ written: CoreLibraryStore.Library,
        from base: CoreLibraryStore.Library,
        onto stored: CoreLibraryStore.Library
    ) -> CoreLibraryStore.Library {
        CoreLibraryStore.Library(
            connections: rebased(written.connections, from: base.connections, onto: stored.connections),
            groups: rebased(written.groups, from: base.groups, onto: stored.groups),
            tags: rebased(written.tags, from: base.tags, onto: stored.tags)
        )
    }
}
