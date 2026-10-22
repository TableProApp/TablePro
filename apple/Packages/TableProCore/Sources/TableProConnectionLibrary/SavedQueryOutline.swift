import Foundation

public protocol SavedQueryRepresentable {
    var id: UUID { get }
    var name: String { get }
    var query: String { get }
    var keyword: String? { get set }
    var folderId: UUID? { get }
    var connectionId: UUID? { get }
    var sortOrder: Int { get }
    var createdAt: Date { get }
}

public protocol SavedQueryFolderRepresentable: LibraryGroupRepresentable {
    var connectionId: UUID? { get }
}

public enum SavedQueryOutlineID: Hashable, Sendable {
    case folder(UUID)
    case query(UUID)
}

public enum SavedQueryOutlineNode<Folder: SavedQueryFolderRepresentable, Query: SavedQueryRepresentable>: Identifiable {
    case folder(Folder, children: [SavedQueryOutlineNode])
    case query(Query)

    public var id: SavedQueryOutlineID {
        switch self {
        case .folder(let folder, _):
            return .folder(folder.id)
        case .query(let query):
            return .query(query.id)
        }
    }

    public var children: [SavedQueryOutlineNode]? {
        switch self {
        case .folder(_, let children):
            return children
        case .query:
            return nil
        }
    }
}

extension SavedQueryOutlineNode: Equatable where Folder: Equatable, Query: Equatable {}

extension SavedQueryOutlineNode: Hashable where Folder: Hashable, Query: Hashable {}

extension SavedQueryOutlineNode: Sendable where Folder: Sendable, Query: Sendable {}

public struct SavedQueryFolderRow<Folder: SavedQueryFolderRepresentable>: Identifiable {
    public let folder: Folder
    public let depth: Int

    public var id: UUID { folder.id }
}

extension SavedQueryFolderRow: Equatable where Folder: Equatable {}

extension SavedQueryFolderRow: Sendable where Folder: Sendable {}

public enum SavedQueryOutline {
    public static func isVisible(scope: UUID?, to connectionId: UUID) -> Bool {
        scope == nil || scope == connectionId
    }

    public static func visible<Query: SavedQueryRepresentable>(_ queries: [Query], to connectionId: UUID) -> [Query] {
        queries.filter { isVisible(scope: $0.connectionId, to: connectionId) }
    }

    public static func visible<Folder: SavedQueryFolderRepresentable>(_ folders: [Folder], to connectionId: UUID) -> [Folder] {
        folders.filter { isVisible(scope: $0.connectionId, to: connectionId) }
    }

    // Mac folders nest without limit, so the graph's depth checks are never asked here.
    public static func build<Folder: SavedQueryFolderRepresentable, Query: SavedQueryRepresentable>(
        folders: [Folder],
        queries: [Query]
    ) -> [SavedQueryOutlineNode<Folder, Query>] {
        let graph = LibraryGroupGraph(groups: folders)
        let foldersById = firstById(folders)
        let queriesByFolder = Dictionary(grouping: queries) { query -> UUID? in
            query.folderId.flatMap { graph.contains($0) ? $0 : nil }
        }

        var visited: Set<UUID> = []
        func nodes(under parentId: UUID?) -> [SavedQueryOutlineNode<Folder, Query>] {
            var result: [SavedQueryOutlineNode<Folder, Query>] = []
            for id in graph.sortedChildIds(of: parentId, mode: .manual) where visited.insert(id).inserted {
                guard let folder = foldersById[id] else { continue }
                result.append(.folder(folder, children: nodes(under: id)))
            }
            for query in (queriesByFolder[parentId] ?? []).sorted(by: queryPrecedes) {
                result.append(.query(query))
            }
            return result
        }
        return nodes(under: nil)
    }

    public static func folderRows<Folder: SavedQueryFolderRepresentable>(_ folders: [Folder]) -> [SavedQueryFolderRow<Folder>] {
        let foldersById = firstById(folders)
        return LibraryGroupGraph(groups: folders).flattened(mode: .manual).compactMap { entry in
            foldersById[entry.id].map { SavedQueryFolderRow(folder: $0, depth: entry.depth) }
        }
    }

    // A folder stays while anything under it matches, so a hit never hides under an empty-looking ancestor.
    public static func filter<Folder: SavedQueryFolderRepresentable, Query: SavedQueryRepresentable>(
        _ nodes: [SavedQueryOutlineNode<Folder, Query>],
        matching text: String
    ) -> [SavedQueryOutlineNode<Folder, Query>] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nodes }
        return filtered(nodes, term: term)
    }

    private static func filtered<Folder: SavedQueryFolderRepresentable, Query: SavedQueryRepresentable>(
        _ nodes: [SavedQueryOutlineNode<Folder, Query>],
        term: String
    ) -> [SavedQueryOutlineNode<Folder, Query>] {
        nodes.compactMap { node -> SavedQueryOutlineNode<Folder, Query>? in
            switch node {
            case .query(let query):
                return matches(query, term: term) ? node : nil
            case .folder(let folder, let children):
                let kept = filtered(children, term: term)
                guard !kept.isEmpty || folder.name.localizedCaseInsensitiveContains(term) else { return nil }
                return .folder(folder, children: kept)
            }
        }
    }

    private static func matches<Query: SavedQueryRepresentable>(_ query: Query, term: String) -> Bool {
        query.name.localizedCaseInsensitiveContains(term)
            || query.keyword?.localizedCaseInsensitiveContains(term) == true
            || query.query.localizedCaseInsensitiveContains(term)
    }

    private static func queryPrecedes<Query: SavedQueryRepresentable>(_ lhs: Query, _ rhs: Query) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func firstById<Folder: SavedQueryFolderRepresentable>(_ folders: [Folder]) -> [UUID: Folder] {
        var byId: [UUID: Folder] = [:]
        for folder in folders where byId[folder.id] == nil {
            byId[folder.id] = folder
        }
        return byId
    }
}
