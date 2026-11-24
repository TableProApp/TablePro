import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting
import Testing

struct MySQLForeignKeyCatalogTests {
    private func key(
        _ name: String,
        _ column: String,
        _ table: String,
        _ referencedColumn: String,
        referencedSchema: String? = "shop",
        onDelete: String = "RESTRICT",
        onUpdate: String = "RESTRICT"
    ) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: name,
            column: column,
            referencedTable: table,
            referencedColumn: referencedColumn,
            referencedSchema: referencedSchema,
            onDelete: onDelete,
            onUpdate: onUpdate
        )
    }

    @Test("Under NO_BACKSLASH_ESCAPES the driver writes a backslash as it is, and doubles it otherwise")
    func literalsFollowTheSession() {
        let literal = SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes], enabled: []
        )
        let escaping = SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes, enabled: .backslashEscapesInSingleQuotes
        )

        #expect(MySQLDriver.stringEscapes(for: .mysql, session: literal, isDatabend: false) == .standard)
        #expect(MySQLDriver.stringEscapes(for: .mysql, session: escaping, isDatabend: false) == .mysql)
        #expect(MySQLDriver.stringEscapes(for: .mysql, session: nil, isDatabend: false) == .mysql)
        #expect(MySQLDriver.stringEscapes(for: .databend, session: nil, isDatabend: true) == .backslash)
    }

    @Test("A key into its own database has no schema, one into another database keeps it")
    func referencedSchemaOnlyWhenItDiffers() {
        let keys = MySQLDriver.foreignKeys([
            key("fk_customer", "customer_id", "customers", "id"),
            key("fk_region", "region_id", "regions", "id", referencedSchema: "geo"),
        ], database: "shop")
        let schemas = keys.map { $0.referencedSchema }
        let tables = keys.map { $0.referencedTable }

        #expect(tables == ["customers", "regions"])
        #expect(schemas == [nil, "geo"])
    }

    @Test("A composite key keeps one name across its column pairs, in key order, with its actions")
    func compositeKeyKeepsItsNameAndActions() {
        let keys = MySQLDriver.foreignKeys([
            key("fk_user", "tid", "users", "tenant_id", onDelete: "CASCADE", onUpdate: "SET NULL"),
            key("fk_user", "uid", "users", "id", onDelete: "CASCADE", onUpdate: "SET NULL"),
        ], database: "shop")
        let names = keys.map { $0.name }
        let columns = keys.map { $0.column }
        let actions = keys.map { "\($0.onDelete) \($0.onUpdate)" }

        #expect(names == ["fk_user", "fk_user"])
        #expect(columns == ["tid", "uid"])
        #expect(actions == ["CASCADE SET NULL", "CASCADE SET NULL"])
    }

    @Test("Indexes of a table in another database are read from that database")
    func indexStatement() {
        #expect(MySQLDriver.showIndexStatement(table: "regions", database: "geo") == "SHOW INDEX FROM `geo`.`regions`")
        #expect(MySQLDriver.showIndexStatement(table: "a`b", database: nil) == "SHOW INDEX FROM `a``b`")
    }
}
