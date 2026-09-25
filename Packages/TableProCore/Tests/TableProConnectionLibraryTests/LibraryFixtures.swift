import Foundation
@testable import TableProConnectionLibrary

struct FixtureConnection: LibraryConnectionRepresentable {
    var id = UUID()
    var name: String
    var host = "localhost"
    var database = ""
    var username = ""
    var libraryTypeName = "PostgreSQL"
    var groupId: UUID?
    var tagIds: [UUID] = []
    var sortOrder = 0
    var isFavorite = false
}

struct FixtureGroup: LibraryGroupRepresentable {
    var id = UUID()
    var name: String
    var parentId: UUID?
    var sortOrder = 0
}

struct FixtureTag: LibraryTagRepresentable {
    var id = UUID()
    var name: String
}

func request(
    connections: [FixtureConnection],
    groups: [FixtureGroup] = [],
    tags: [FixtureTag] = [],
    sortMode: LibrarySortMode = .manual,
    query: LibraryQuery = LibraryQuery(),
    favoritesOrder: [UUID] = [],
    lastConnected: [UUID: Date] = [:],
    includesRecent: Bool = true,
    externalSections: [LibraryExternalSection] = []
) -> LibraryOutlineRequest<FixtureConnection, FixtureGroup, FixtureTag> {
    LibraryOutlineRequest(
        connections: connections,
        groups: groups,
        tags: tags,
        sortMode: sortMode,
        query: query,
        favoritesOrder: favoritesOrder,
        lastConnected: lastConnected,
        includesRecent: includesRecent,
        externalSections: externalSections
    )
}

func childIds(_ nodes: [LibraryNode]) -> [UUID] {
    nodes.map { node in
        switch node {
        case .group(let id, _, _):
            return id
        case .connection(let id):
            return id
        }
    }
}

func findGroup(_ id: UUID, in nodes: [LibraryNode]) -> LibraryNode? {
    for node in nodes {
        guard case .group(let nodeId, let children, _) = node else { continue }
        if nodeId == id { return node }
        if let found = findGroup(id, in: children) { return found }
    }
    return nil
}
