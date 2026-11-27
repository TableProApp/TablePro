import Foundation

public enum LibraryOrdering {
    public static func nextSortOrder(after existing: [Int]) -> Int {
        (existing.max() ?? -1) + 1
    }

    public static func reordered(_ siblings: [UUID], moving: [UUID], before: UUID?) -> [UUID] {
        let movingSet = Set(moving)
        var remaining = siblings.filter { !movingSet.contains($0) }
        let insertion = before.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        var seen: Set<UUID> = []
        let unique = moving.filter { seen.insert($0).inserted }
        remaining.insert(contentsOf: unique, at: insertion)
        return remaining
    }

    public static func ranks(for ordered: [UUID]) -> [UUID: Int] {
        var ranks: [UUID: Int] = [:]
        for (index, id) in ordered.enumerated() where ranks[id] == nil {
            ranks[id] = index
        }
        return ranks
    }

    public static func favoritesOrder(_ current: [UUID], inserting: [UUID], before: UUID?) -> [UUID] {
        reordered(current, moving: inserting, before: before)
    }

    public static func favoritesOrder(_ current: [UUID], removing: Set<UUID>) -> [UUID] {
        current.filter { !removing.contains($0) }
    }

    // A list that shows one project orders only what it shows, so every other id keeps its place in the saved order.
    public static func favoritesOrder(_ saved: [UUID], scoped: [UUID], reorderedTo updated: [UUID]) -> [UUID] {
        let inScope = Set(scoped).union(updated)
        var seen: Set<UUID> = []
        var pending = updated.filter { seen.insert($0).inserted }[...]
        var merged: [UUID] = []
        var afterLastSlot: Int?
        for id in saved {
            guard inScope.contains(id) else {
                merged.append(id)
                continue
            }
            guard let next = pending.popFirst() else { continue }
            merged.append(next)
            afterLastSlot = merged.count
        }
        merged.insert(contentsOf: pending, at: afterLastSlot ?? merged.count)
        return merged
    }

    public static func favoritesOrder(_ current: [UUID], keeping favorites: Set<UUID>) -> [UUID] {
        var seen: Set<UUID> = []
        return current.filter { favorites.contains($0) && seen.insert($0).inserted }
    }
}
