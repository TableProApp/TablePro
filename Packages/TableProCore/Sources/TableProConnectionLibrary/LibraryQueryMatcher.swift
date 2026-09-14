import Foundation

public struct LibraryQueryMatcher: Sendable {
    public let query: LibraryQuery
    private let tagNamesById: [UUID: String]

    public init<Tag: LibraryTagRepresentable>(query: LibraryQuery, tags: [Tag]) {
        self.query = query
        var names: [UUID: String] = [:]
        for tag in tags where names[tag.id] == nil {
            names[tag.id] = tag.name
        }
        tagNamesById = names
    }

    public func matchesText<Connection: LibraryConnectionRepresentable>(_ connection: Connection) -> Bool {
        let term = query.trimmedText
        guard !term.isEmpty else { return true }
        let fields = [
            connection.name,
            connection.host,
            connection.database,
            connection.username,
            connection.libraryTypeName
        ] + connection.tagIds.compactMap { tagNamesById[$0] }
        return fields.contains { $0.localizedCaseInsensitiveContains(term) }
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
        let term = query.trimmedText
        guard !term.isEmpty else { return false }
        return groupName.localizedCaseInsensitiveContains(term)
    }

    public func matches(_ entry: LibraryExternalEntry) -> Bool {
        guard query.tagIds.isEmpty else { return false }
        let term = query.trimmedText
        guard !term.isEmpty else { return true }
        return [entry.name, entry.host, entry.database, entry.username, entry.typeName]
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }
}
