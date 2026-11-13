import Foundation
@testable import TableProMobile
import TableProModels
import TableProSQLGrammar
import Testing

struct ReadOnlyBareNameGuardTests {
    private struct Unreachable: Error {}

    // The catalog Oracle 23ai answered for a schema with function PURGE and table ORDERS(ID, PURGE).
    private static let catalog: SQLCallableCatalogCache.Reader = { query in
        if query == SQLCallableCatalog.query { return [["F", "PURGE"]] }
        return [["0", "1", nil, "ID"], ["0", "1", nil, "PURGE"]]
    }

    private static func refuses(_ sql: String, level: SafeModeLevel = .readOnly, read: @escaping SQLCallableCatalogCache.Reader = catalog) async -> Bool {
        await ReadOnlyFunctionGuard.refusesBareName(
            sql, databaseType: .oracle, level: level, connectionId: UUID(), schema: nil, read: read
        )
    }

    @Test("Oracle Read-Only refuses a function named bare and runs the column of the same name")
    func functionNamedBare() async {
        #expect(await Self.refuses("SELECT purge FROM dual"))
        #expect(await Self.refuses("SELECT pkg.purge FROM dual"))
        #expect(!(await Self.refuses("SELECT purge FROM orders")))
        #expect(!(await Self.refuses("SELECT id FROM orders")))
    }

    @Test("Only Read-Only refuses, and a catalog that cannot be read refuses")
    func onlyReadOnly() async {
        #expect(!(await Self.refuses("SELECT purge FROM dual", level: .confirmWrites)))
        #expect(await Self.refuses("SELECT id FROM orders", read: { _ in throw Unreachable() }))
        #expect(!(await ReadOnlyFunctionGuard.refusesBareName(
            "SELECT purge FROM dual", databaseType: .postgresql, level: .readOnly, connectionId: UUID(), schema: nil,
            read: Self.catalog
        )))
    }
}
