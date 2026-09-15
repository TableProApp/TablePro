//
//  ConnectionLibraryConformances.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProImport

extension DatabaseConnection: LibraryConnectionRepresentable {
    internal var libraryTypeName: String { type.displayName }
}

extension ConnectionGroup: LibraryGroupRepresentable {}

extension ConnectionTag: LibraryTagRepresentable {}

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
