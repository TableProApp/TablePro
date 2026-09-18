import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

@Suite("PostgreSQL foreign key query")
struct PostgreSQLForeignKeyQueryTests {
    private func row(_ side: String, _ attributeNumber: Int, _ attributeName: String) -> [String?] {
        var cells: [String?] = Array(repeating: nil, count: PostgreSQLCatalogForeignKeys.Column.allCases.count)
        cells[PostgreSQLCatalogForeignKeys.Column.constraintIdentity.rawValue] = "42"
        cells[PostgreSQLCatalogForeignKeys.Column.constraintName.rawValue] = "fk_xy"
        cells[PostgreSQLCatalogForeignKeys.Column.referencedSchema.rawValue] = "sales"
        cells[PostgreSQLCatalogForeignKeys.Column.referencedTable.rawValue] = "parent"
        cells[PostgreSQLCatalogForeignKeys.Column.deleteAction.rawValue] = "c"
        cells[PostgreSQLCatalogForeignKeys.Column.updateAction.rawValue] = "a"
        cells[PostgreSQLCatalogForeignKeys.Column.sourceKeys.rawValue] = "{2,3}"
        cells[PostgreSQLCatalogForeignKeys.Column.referencedKeys.rawValue] = "{1,2}"
        cells[PostgreSQLCatalogForeignKeys.Column.side.rawValue] = side
        cells[PostgreSQLCatalogForeignKeys.Column.attributeNumber.rawValue] = String(attributeNumber)
        cells[PostgreSQLCatalogForeignKeys.Column.attributeName.rawValue] = attributeName
        return cells
    }

    @Test("a composite key decodes to one pair per column, in key order")
    func decodesOnePairPerColumn() {
        let rows = [row("s", 2, "a"), row("s", 3, "b"), row("r", 1, "x"), row("r", 2, "y")]

        let keys = PostgreSQLCatalogForeignKeys.foreignKeys(from: rows)

        #expect(keys.map(\.column) == ["a", "b"])
        #expect(keys.map(\.referencedColumn) == ["x", "y"])
        #expect(keys.allSatisfy { $0.referencedSchema == "sales" })
        #expect(keys.allSatisfy { $0.onDelete == "CASCADE" && $0.onUpdate == "NO ACTION" })
    }

    @Test("the constraint is found by the table's own schema and name")
    func filtersOnSchemaAndTable() {
        let query = PostgreSQLDriver.foreignKeysQuery(schema: "sales", table: "orders", serverVersionNumber: 170_011)

        #expect(query.contains("ns.nspname = 'sales'"))
        #expect(query.contains("cl.relname = 'orders'"))
    }

    @Test("quotes in the schema and table names are doubled")
    func escapesQuotes() {
        let query = PostgreSQLDriver.foreignKeysQuery(schema: "o'brien", table: "it's", serverVersionNumber: 170_011)

        #expect(query.contains("ns.nspname = 'o''brien'"))
        #expect(query.contains("cl.relname = 'it''s'"))
    }

    @Test("a Redshift server never receives the PostgreSQL 11 clone filter")
    func redshiftKeepsPortableQuery() {
        let redshift = PostgreSQLDriver.foreignKeysQuery(schema: "public", table: "t", serverVersionNumber: 80_002)
        let modern = PostgreSQLDriver.foreignKeysQuery(schema: "public", table: "t", serverVersionNumber: 170_011)

        #expect(!redshift.contains("conparentid"))
        #expect(!redshift.contains("generate_subscripts"))
        #expect(modern.contains("conparentid"))
    }
}
