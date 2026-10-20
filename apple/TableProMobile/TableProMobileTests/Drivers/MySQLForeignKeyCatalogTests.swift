import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct MySQLForeignKeyCatalogTests {
    // CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, DELETE_RULE,
    // UPDATE_RULE, TABLE_SCHEMA, REFERENCED_TABLE_SCHEMA, in the order the catalog query selects them.
    private func row(
        _ name: String,
        _ column: String,
        _ table: String,
        _ referencedColumn: String,
        schema: String = "shop",
        referencedSchema: String? = "shop",
        onDelete: String? = "RESTRICT",
        onUpdate: String? = "RESTRICT"
    ) -> [String?] {
        [name, column, table, referencedColumn, onDelete, onUpdate, schema, referencedSchema]
    }

    @Test("The catalog read filters on the database it is asked for")
    func readsTheRequestedDatabase() {
        let query = MySQLDriver.foreignKeyCatalogQuery(table: "orders", database: "crm")

        #expect(query.contains("kcu.TABLE_SCHEMA = 'crm'"))
        #expect(query.contains("kcu.TABLE_NAME = 'orders'"))
        #expect(query.contains("kcu.REFERENCED_TABLE_SCHEMA"))
        #expect(!query.contains("DATABASE()"))
    }

    @Test("With no database the catalog read follows the session's current one")
    func readsTheSessionDatabase() {
        let query = MySQLDriver.foreignKeyCatalogQuery(table: "orders", database: nil)

        #expect(query.contains("kcu.TABLE_SCHEMA = DATABASE()"))
    }

    @Test("Quotes and backslashes in the database and table names are escaped")
    func escapesNames() {
        let query = MySQLDriver.foreignKeyCatalogQuery(table: #"o'b\x"#, database: #"c'r\m"#)

        #expect(query.contains(#"kcu.TABLE_SCHEMA = 'c''r\\m'"#))
        #expect(query.contains(#"kcu.TABLE_NAME = 'o''b\\x'"#))
    }

    @Test("A key into its own database has no schema, one into another database keeps it")
    func referencedSchemaOnlyWhenItDiffers() {
        let keys = MySQLDriver.foreignKeys(fromCatalogRows: [
            row("fk_customer", "customer_id", "customers", "id"),
            row("fk_region", "region_id", "regions", "id", referencedSchema: "geo"),
        ])

        #expect(keys.map(\.name) == ["fk_customer", "fk_region"])
        #expect(keys.map(\.referencedTable) == ["customers", "regions"])
        #expect(keys.map(\.referencedSchema) == [nil, "geo"])
    }

    @Test("A composite key keeps one name across its column pairs, in key order")
    func compositeKeyKeepsItsName() {
        let keys = MySQLDriver.foreignKeys(fromCatalogRows: [
            row("fk_user", "tid", "users", "tenant_id"),
            row("fk_user", "uid", "users", "id"),
        ])

        #expect(keys.map(\.name) == ["fk_user", "fk_user"])
        #expect(keys.map(\.column) == ["tid", "uid"])
        #expect(keys.map(\.referencedColumn) == ["tenant_id", "id"])
    }

    @Test("Actions come from the catalog, and a missing one reads as NO ACTION")
    func actions() {
        let keys = MySQLDriver.foreignKeys(fromCatalogRows: [
            row("fk_a", "a", "p", "id", onDelete: "CASCADE", onUpdate: "SET NULL"),
            row("fk_b", "b", "p", "id", onDelete: nil, onUpdate: nil),
        ])

        #expect(keys.map(\.onDelete) == ["CASCADE", "NO ACTION"])
        #expect(keys.map(\.onUpdate) == ["SET NULL", "NO ACTION"])
    }

    @Test("A row missing a name or a column is skipped")
    func incompleteRowsAreSkipped() {
        var nameless = row("fk_a", "a", "p", "id")
        nameless[0] = nil
        let short = Array(row("fk_b", "b", "p", "id").prefix(6))

        #expect(MySQLDriver.foreignKeys(fromCatalogRows: [nameless, short]).isEmpty)
    }

    @Test("Indexes of a table in another database are read from that database")
    func indexStatement() {
        #expect(MySQLDriver.showIndexStatement(table: "regions", database: "geo") == "SHOW INDEX FROM `geo`.`regions`")
        #expect(MySQLDriver.showIndexStatement(table: "a`b", database: nil) == "SHOW INDEX FROM `a``b`")
    }
}
