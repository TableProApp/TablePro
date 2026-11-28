import Foundation
import TableProConnectionLibrary
import TableProImport

extension DatabaseConnection: LibraryConnectionRepresentable {
    internal var libraryTypeName: String { type.displayName }
}

extension ConnectionGroup: LibraryGroupRepresentable {}

extension ConnectionTag: LibraryTagRepresentable {}

extension SQLFavorite: SavedQueryRepresentable {}

internal extension DatabaseConnection {
    var libraryExternalEntry: LibraryExternalEntry {
        LibraryExternalEntry(
            id: id,
            name: name,
            host: host,
            database: database,
            username: username,
            typeName: type.displayName
        )
    }
}

internal extension LinkedConnection {
    var libraryEntry: LibraryExternalEntry {
        LibraryExternalEntry(
            id: id,
            name: connection.name,
            host: connection.host,
            database: connection.database,
            username: connection.username,
            typeName: DatabaseType(rawValue: connection.type).displayName
        )
    }
}
