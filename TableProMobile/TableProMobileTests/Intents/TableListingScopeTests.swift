import Foundation
@testable import TableProMobile
import Testing

@Suite("TableListingScope")
struct TableListingScopeTests {
    private let sqlite = ConnectionEntity(id: UUID(), name: "Chinook", host: "", databaseType: "SQLite")
    private let postgres = ConnectionEntity(id: UUID(), name: "Prod", host: "db.example.com", databaseType: "PostgreSQL")

    @Test("a connection with no database picked lists its own tables")
    func connectionAloneListsItsTables() {
        let scope = TableListingScope.resolve(scoped: nil, connection: sqlite)

        #expect(scope == TableListingScope(connectionId: sqlite.id, namespace: nil))
    }

    @Test("a picked schema narrows the list to that schema")
    func pickedSchemaNarrowsTheList() {
        let schema = DatabaseEntity(id: "public", name: "public", kind: .schema)

        let scope = TableListingScope.resolve(scoped: (postgres, schema), connection: postgres)

        #expect(scope == TableListingScope(connectionId: postgres.id, namespace: "public"))
    }

    @Test("nothing is listed before a connection is picked")
    func noConnectionListsNothing() {
        #expect(TableListingScope.resolve(scoped: nil, connection: nil) == nil)
    }
}
