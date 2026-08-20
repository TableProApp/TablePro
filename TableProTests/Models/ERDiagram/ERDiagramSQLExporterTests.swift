//
//  ERDiagramSQLExporterTests.swift
//  TableProTests
//
//  Tests CREATE TABLE + FOREIGN KEY DDL generation from diagram metadata.
//

import Foundation
@testable import TablePro
import Testing

@Suite("ER diagram SQL exporter")
struct ERDiagramSQLExporterTests {
    private let quote: (String) -> String = { "\"\($0)\"" }

    private func column(
        _ name: String,
        type: String = "integer",
        nullable: Bool = false,
        primaryKey: Bool = false,
        defaultValue: String? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            name: name,
            dataType: type,
            isNullable: nullable,
            isPrimaryKey: primaryKey,
            defaultValue: defaultValue
        )
    }

    private func foreignKey(
        _ name: String,
        column: String,
        references table: String,
        _ refColumn: String = "id",
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) -> ForeignKeyInfo {
        ForeignKeyInfo(
            name: name,
            column: column,
            referencedTable: table,
            referencedColumn: refColumn,
            onDelete: onDelete,
            onUpdate: onUpdate
        )
    }

    @Test("Generates a CREATE TABLE statement")
    func createTableBasic() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["users"],
            allColumns: ["users": [column("id", primaryKey: true), column("name", type: "varchar", nullable: true)]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("CREATE TABLE \"users\" ("))
        #expect(sql.contains("\"id\" integer NOT NULL PRIMARY KEY"))
        #expect(sql.contains("\"name\" varchar"))
        #expect(sql.hasSuffix(");"))
    }

    @Test("Nullable columns omit NOT NULL")
    func nullableColumnOmitsNotNull() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["users"],
            allColumns: ["users": [column("name", type: "varchar", nullable: true)]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(!sql.contains("\"name\" varchar NOT NULL"))
    }

    @Test("DEFAULT clause is emitted when present")
    func defaultValueEmitted() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["t"],
            allColumns: ["t": [column("status", type: "varchar", nullable: false, defaultValue: "'active'")]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("\"status\" varchar NOT NULL DEFAULT 'active'"))
    }

    @Test("Unquoted string default is quoted")
    func unquotedStringDefaultIsQuoted() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["t"],
            allColumns: ["t": [column("status", type: "varchar", nullable: false, defaultValue: "active")]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("\"status\" varchar NOT NULL DEFAULT 'active'"))
        #expect(!sql.contains("DEFAULT active"))
    }

    @Test("Numeric, expression, and keyword defaults pass through unquoted")
    func nonLiteralDefaultsPassThrough() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["t"],
            allColumns: ["t": [
                column("count", type: "integer", nullable: false, defaultValue: "0"),
                column("created", type: "timestamp", nullable: false, defaultValue: "CURRENT_TIMESTAMP"),
                column("uid", type: "uuid", nullable: false, defaultValue: "gen_random_uuid()")
            ]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("\"count\" integer NOT NULL DEFAULT 0"))
        #expect(sql.contains("\"created\" timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP"))
        #expect(sql.contains("\"uid\" uuid NOT NULL DEFAULT gen_random_uuid()"))
    }

    @Test("Non-finite numeric-looking string defaults are quoted")
    func infinityLikeStringDefaultIsQuoted() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["t"],
            allColumns: ["t": [
                column("a", type: "varchar", nullable: false, defaultValue: "inf"),
                column("b", type: "varchar", nullable: false, defaultValue: "nan")
            ]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("\"a\" varchar NOT NULL DEFAULT 'inf'"))
        #expect(sql.contains("\"b\" varchar NOT NULL DEFAULT 'nan'"))
        #expect(!sql.contains("DEFAULT inf"))
        #expect(!sql.contains("DEFAULT nan"))
    }

    @Test("Composite primary key becomes a trailing clause")
    func compositePrimaryKey() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["t"],
            allColumns: ["t": [column("a", primaryKey: true), column("b", primaryKey: true)]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("PRIMARY KEY (\"a\", \"b\")"))
        #expect(!sql.contains("\"a\" integer NOT NULL PRIMARY KEY"))
    }

    @Test("Single primary key is inline on the column")
    func singlePrimaryKeyInline() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["t"],
            allColumns: ["t": [column("id", primaryKey: true)]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("\"id\" integer NOT NULL PRIMARY KEY"))
        #expect(!sql.contains("PRIMARY KEY ("))
    }

    @Test("SQLite inlines foreign keys and emits no ALTER TABLE")
    func sqliteInlineForeignKey() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["users", "orders"],
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true), column("user_id")]
            ],
            allForeignKeys: ["orders": [foreignKey("fk_user", column: "user_id", references: "users")]],
            isSQLite: true,
            quoteIdentifier: quote
        )
        #expect(sql.contains("FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\")"))
        #expect(!sql.contains("ALTER TABLE"))
    }

    @Test("Non-SQLite emits ALTER TABLE ADD CONSTRAINT for foreign keys")
    func nonSQLiteAlterForeignKey() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["users", "orders"],
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true), column("user_id")]
            ],
            allForeignKeys: ["orders": [foreignKey("fk_user", column: "user_id", references: "users")]],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains(
            "ALTER TABLE \"orders\" ADD CONSTRAINT \"fk_user\" FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\");"
        ))
    }

    @Test("All CREATE TABLE statements precede ALTER TABLE for circular foreign keys")
    func circularForeignKeyOrdering() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["a", "b"],
            allColumns: [
                "a": [column("id", primaryKey: true), column("b_id")],
                "b": [column("id", primaryKey: true), column("a_id")]
            ],
            allForeignKeys: [
                "a": [foreignKey("fk_a_b", column: "b_id", references: "b")],
                "b": [foreignKey("fk_b_a", column: "a_id", references: "a")]
            ],
            isSQLite: false,
            quoteIdentifier: quote
        )
        let firstAlter = sql.range(of: "ALTER TABLE")
        let lastCreate = sql.range(of: "CREATE TABLE", options: .backwards)
        #expect(firstAlter != nil)
        #expect(lastCreate != nil)
        if let firstAlter, let lastCreate {
            #expect(lastCreate.lowerBound < firstAlter.lowerBound)
        }
    }

    @Test("Composite foreign key is grouped into one constraint")
    func compositeForeignKeyGrouped() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["parent", "child"],
            allColumns: [
                "parent": [column("p1", primaryKey: true), column("p2", primaryKey: true)],
                "child": [column("id", primaryKey: true), column("c1"), column("c2")]
            ],
            allForeignKeys: ["child": [
                foreignKey("fk_x", column: "c1", references: "parent", "p1"),
                foreignKey("fk_x", column: "c2", references: "parent", "p2")
            ]],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains(
            "ADD CONSTRAINT \"fk_x\" FOREIGN KEY (\"c1\", \"c2\") REFERENCES \"parent\" (\"p1\", \"p2\");"
        ))
    }

    @Test("ON DELETE CASCADE is included")
    func onDeleteCascadeIncluded() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["users", "orders"],
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true), column("user_id")]
            ],
            allForeignKeys: ["orders": [foreignKey("fk_user", column: "user_id", references: "users", onDelete: "CASCADE")]],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("ON DELETE CASCADE"))
    }

    @Test("NO ACTION referential actions are omitted")
    func noActionOmitted() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["users", "orders"],
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true), column("user_id")]
            ],
            allForeignKeys: ["orders": [foreignKey("fk_user", column: "user_id", references: "users")]],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(!sql.contains("ON DELETE"))
        #expect(!sql.contains("ON UPDATE"))
    }

    @Test("Tables with no columns are skipped")
    func emptyTableSkipped() {
        let sql = ERDiagramSQLExporter.generate(
            tableNames: ["users", "ghost"],
            allColumns: ["users": [column("id", primaryKey: true)]],
            allForeignKeys: [:],
            isSQLite: false,
            quoteIdentifier: quote
        )
        #expect(sql.contains("CREATE TABLE \"users\""))
        #expect(!sql.contains("\"ghost\""))
    }
}
