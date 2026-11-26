//
//  LibraryImage.swift
//  TablePro
//

import Foundation

// The connection library as one value, the way the core writes it in one commit.
struct LibraryImage: Equatable {
    var connections: [DatabaseConnection]
    var groups: [ConnectionGroup]
    var tags: [ConnectionTag]
    // The favourites in the order this Mac shows them; `isFavorite` on each connection says which ones are.
    var favoritesOrder: [UUID]

    static let empty = LibraryImage(connections: [], groups: [], tags: [], favoritesOrder: [])

    // The core holds one record per id. connections.json could hold two, and every lookup by id found the first.
    func keepingFirstOfEachId() -> LibraryImage {
        var copy = self
        copy.connections = Self.firstOfEachId(connections)
        copy.groups = Self.firstOfEachId(groups)
        copy.tags = Self.firstOfEachId(tags)
        return copy
    }

    private static func firstOfEachId<Element: Identifiable>(_ elements: [Element]) -> [Element] where Element.ID == UUID {
        var seen: Set<UUID> = []
        return elements.filter { seen.insert($0.id).inserted }
    }

    // The core keeps one list: the favourites in order. One the order does not name yet follows by name, as ADR 0010 reads
    // the favourites order, and an id this build cannot read keeps its place.
    func favorites(keeping held: Set<UUID>) -> [UUID] {
        let favorites = Set(connections.filter(\.isFavorite).map(\.id))
        var seen: Set<UUID> = []
        var ordered = favoritesOrder.filter { (favorites.contains($0) || held.contains($0)) && seen.insert($0).inserted }
        let unordered = connections
            .filter { $0.isFavorite && !seen.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        ordered.append(contentsOf: unordered.map(\.id))
        return ordered
    }
}
