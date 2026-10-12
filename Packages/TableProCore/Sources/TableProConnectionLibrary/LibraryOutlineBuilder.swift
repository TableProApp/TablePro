import Foundation

public struct LibraryOutlineRequest<
    Connection: LibraryConnectionRepresentable,
    Group: LibraryGroupRepresentable,
    Tag: LibraryTagRepresentable
> {
    public var connections: [Connection]
    public var groups: [Group]
    public var tags: [Tag]
    public var sortMode: LibrarySortMode
    public var query: LibraryQuery
    public var favoritesOrder: [UUID]
    public var lastConnected: [UUID: Date]
    public var recentLimit: Int
    public var includesFavorites: Bool
    public var includesRecent: Bool
    public var externalSections: [LibraryExternalSection]

    public init(
        connections: [Connection],
        groups: [Group],
        tags: [Tag],
        sortMode: LibrarySortMode = .manual,
        query: LibraryQuery = LibraryQuery(),
        favoritesOrder: [UUID] = [],
        lastConnected: [UUID: Date] = [:],
        recentLimit: Int = LibraryOutlineBuilder.defaultRecentLimit,
        includesFavorites: Bool = true,
        includesRecent: Bool = true,
        externalSections: [LibraryExternalSection] = []
    ) {
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.sortMode = sortMode
        self.query = query
        self.favoritesOrder = favoritesOrder
        self.lastConnected = lastConnected
        self.recentLimit = recentLimit
        self.includesFavorites = includesFavorites
        self.includesRecent = includesRecent
        self.externalSections = externalSections
    }
}

public enum LibraryOutlineBuilder {
    public static let defaultRecentLimit = 5

    public static func build<Connection, Group, Tag>(
        _ request: LibraryOutlineRequest<Connection, Group, Tag>
    ) -> LibraryOutline {
        let graph = LibraryGroupGraph(groups: request.groups)
        let matcher = LibraryQueryMatcher(query: request.query, tags: request.tags)
        var context = TreeContext(request: request, graph: graph, matcher: matcher)

        var sections: [LibrarySection] = []
        let isQueryActive = request.query.isActive

        if !isQueryActive {
            let favorites = favoriteIds(request).map { LibraryNode.connection(id: $0) }
            if !favorites.isEmpty {
                sections.append(LibrarySection(kind: .favorites, nodes: favorites))
            }
            let recent = recentIds(request).map { LibraryNode.connection(id: $0) }
            if !recent.isEmpty {
                sections.append(LibrarySection(kind: .recent, nodes: recent))
            }
        }

        let tree = context.level(parentId: nil, visited: [], textRelaxed: false)
        if !tree.isEmpty {
            sections.append(LibrarySection(kind: .connections, nodes: tree))
        }

        for external in request.externalSections where !external.kind.acceptsSavedConnections {
            let entries = external.entries
                .filter { !isQueryActive || matcher.matches($0) }
                .sorted { lhs, rhs in
                    let order = lhs.name.localizedStandardCompare(rhs.name)
                    return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
                }
            guard !entries.isEmpty else { continue }
            sections.append(LibrarySection(kind: external.kind, nodes: entries.map { .connection(id: $0.id) }))
        }

        return LibraryOutline(
            sections: sections,
            groupIdsExpandedByQuery: context.expandedByQuery,
            isQueryActive: isQueryActive
        )
    }

    public static func favoriteIds<Connection, Group, Tag>(
        _ request: LibraryOutlineRequest<Connection, Group, Tag>
    ) -> [UUID] {
        guard request.includesFavorites else { return [] }
        let favorites = request.connections.filter(\.isFavorite)
        guard request.sortMode == .manual else {
            return LibrarySorting.sorted(favorites, mode: request.sortMode, lastConnected: request.lastConnected).map(\.id)
        }
        var rank: [UUID: Int] = [:]
        for (index, id) in request.favoritesOrder.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return favorites.sorted { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case let (left?, right?):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return LibrarySorting.connectionPrecedes(lhs, rhs, mode: .name, lastConnected: [:])
            }
        }
        .map(\.id)
    }

    public static func recentIds<Connection, Group, Tag>(
        _ request: LibraryOutlineRequest<Connection, Group, Tag>
    ) -> [UUID] {
        guard request.includesRecent, request.recentLimit > 0 else { return [] }
        let eligible = Set(request.connections.filter { !$0.isFavorite }.map(\.id))
        return request.lastConnected
            .filter { eligible.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.uuidString < rhs.key.uuidString : lhs.value > rhs.value
            }
            .prefix(request.recentLimit)
            .map(\.key)
    }
}

private struct TreeContext<Connection: LibraryConnectionRepresentable, Group: LibraryGroupRepresentable, Tag: LibraryTagRepresentable> {
    let sortMode: LibrarySortMode
    let query: LibraryQuery
    let graph: LibraryGroupGraph
    let matcher: LibraryQueryMatcher
    let connectionsByGroup: [UUID: [Connection]]
    let ungrouped: [Connection]
    var expandedByQuery: Set<UUID> = []

    init(request: LibraryOutlineRequest<Connection, Group, Tag>, graph: LibraryGroupGraph, matcher: LibraryQueryMatcher) {
        sortMode = request.sortMode
        query = request.query
        self.graph = graph
        self.matcher = matcher
        var byGroup: [UUID: [Connection]] = [:]
        var loose: [Connection] = []
        for connection in request.connections {
            if let groupId = connection.groupId, graph.contains(groupId) {
                byGroup[groupId, default: []].append(connection)
            } else {
                loose.append(connection)
            }
        }
        connectionsByGroup = byGroup.mapValues {
            LibrarySorting.sorted($0, mode: request.sortMode, lastConnected: request.lastConnected)
        }
        ungrouped = LibrarySorting.sorted(loose, mode: request.sortMode, lastConnected: request.lastConnected)
    }

    mutating func level(parentId: UUID?, visited: Set<UUID>, textRelaxed: Bool) -> [LibraryNode] {
        var nodes: [LibraryNode] = []
        for groupId in graph.sortedChildIds(of: parentId, mode: sortMode) where !visited.contains(groupId) {
            if let node = group(groupId, visited: visited.union([groupId]), textRelaxed: textRelaxed) {
                nodes.append(node)
            }
        }
        let connections = parentId.map { connectionsByGroup[$0] ?? [] } ?? ungrouped
        nodes += connections
            .filter { includes($0, textRelaxed: textRelaxed) }
            .map { .connection(id: $0.id) }
        return nodes
    }

    private mutating func group(_ id: UUID, visited: Set<UUID>, textRelaxed: Bool) -> LibraryNode? {
        guard query.isActive else {
            let children = level(parentId: id, visited: visited, textRelaxed: false)
            return .group(id: id, children: children, connectionCount: count(children))
        }
        let nameMatches = !textRelaxed && matcher.matchesText(groupName: graph.entries[id]?.name ?? "")
        let childRelaxed = textRelaxed || nameMatches || !query.hasTextTerm
        let children = level(parentId: id, visited: visited, textRelaxed: childRelaxed)
        let keepsEmpty = (nameMatches || textRelaxed) && query.tagIds.isEmpty
        guard !children.isEmpty || keepsEmpty else { return nil }
        if !children.isEmpty {
            expandedByQuery.insert(id)
        }
        return .group(id: id, children: children, connectionCount: count(children))
    }

    private func includes(_ connection: Connection, textRelaxed: Bool) -> Bool {
        guard query.isActive else { return true }
        return textRelaxed ? matcher.matchesTags(connection) : matcher.matches(connection)
    }

    private func count(_ nodes: [LibraryNode]) -> Int {
        nodes.reduce(0) { $0 + $1.connectionCount }
    }
}
