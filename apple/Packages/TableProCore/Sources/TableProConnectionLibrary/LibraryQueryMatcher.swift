import Foundation

public struct LibraryQueryMatcher: Sendable {
    public let query: LibraryQuery
    private let words: [String]
    private let tagNamesById: [UUID: String]
    private let graph: LibraryGroupGraph?

    public init<Tag: LibraryTagRepresentable>(query: LibraryQuery, tags: [Tag], groups graph: LibraryGroupGraph? = nil) {
        self.query = query
        words = query.words
        self.graph = graph
        var names: [UUID: String] = [:]
        for tag in tags where names[tag.id] == nil {
            names[tag.id] = tag.name
        }
        tagNamesById = names
    }

    public func matchesText<Connection: LibraryConnectionRepresentable>(_ connection: Connection) -> Bool {
        guard !words.isEmpty else { return true }
        let fields = [
            connection.name,
            connection.host,
            connection.database,
            connection.username,
            connection.libraryTypeName
        ] + connection.tagIds.compactMap { tagNamesById[$0] } + groupPath(connection.groupId)
        return everyWord(in: fields)
    }

    public func matchesTags<Connection: LibraryConnectionRepresentable>(_ connection: Connection) -> Bool {
        guard !query.tagIds.isEmpty else { return true }
        let ids = Set(connection.tagIds)
        switch query.tagMatch {
        case .any:
            return !query.tagIds.isDisjoint(with: ids)
        case .all:
            return query.tagIds.isSubset(of: ids)
        }
    }

    public func matches<Connection: LibraryConnectionRepresentable>(_ connection: Connection) -> Bool {
        matchesTags(connection) && matchesText(connection)
    }

    public func matchesText(groupName: String) -> Bool {
        !words.isEmpty && everyWord(in: [groupName])
    }

    public func matchesText(groupId: UUID) -> Bool {
        !words.isEmpty && everyWord(in: groupPath(groupId))
    }

    public func matches(_ entry: LibraryExternalEntry) -> Bool {
        guard query.tagIds.isEmpty else { return false }
        guard !words.isEmpty else { return true }
        return everyWord(in: [entry.name, entry.host, entry.database, entry.username, entry.typeName])
    }

    private func groupPath(_ groupId: UUID?) -> [String] {
        guard let groupId, let graph else { return [] }
        return graph.pathNames(to: groupId)
    }

    private func everyWord(in fields: [String]) -> Bool {
        words.allSatisfy { word in
            fields.contains { $0.localizedCaseInsensitiveContains(word) }
        }
    }
}
