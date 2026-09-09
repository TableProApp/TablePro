//
//  SQLiteCreateTableDDLTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProPluginKit

/// Every expectation was checked against sqlite3 3.54.0 before it was written here.
@Suite("SQLite CREATE TABLE DDL")
struct SQLiteCreateTableDDLTests {
    private func definition(
        columns: [PluginColumnDefinition] = [
            PluginColumnDefinition(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true),
            PluginColumnDefinition(name: "parent_id", dataType: "INTEGER")
        ],
        foreignKeys: [PluginForeignKeyDefinition] = [],
        primaryKeyColumns: [String] = []
    ) -> PluginCreateTableDefinition {
        PluginCreateTableDefinition(
            tableName: "child",
            columns: columns,
            foreignKeys: foreignKeys,
            primaryKeyColumns: primaryKeyColumns
        )
    }

    private func foreignKey(
        name: String = "",
        columns: [String] = ["parent_id"],
        referencedColumns: [String] = ["id"],
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) -> PluginForeignKeyDefinition {
        PluginForeignKeyDefinition(
            name: name, columns: columns, referencedTable: "parent",
            referencedColumns: referencedColumns, onDelete: onDelete, onUpdate: onUpdate
        )
    }

    @Test("an unnamed foreign key emits a bare FOREIGN KEY clause")
    func unnamedForeignKey() throws {
        let sql = try #require(sqliteCreateTableSQL(definition: definition(foreignKeys: [foreignKey()])))
        #expect(sql.contains("FOREIGN KEY (`parent_id`) REFERENCES `parent` (`id`)"))
        #expect(!sql.contains("CONSTRAINT"))
    }

    @Test("a named foreign key keeps its CONSTRAINT clause")
    func namedForeignKey() throws {
        let sql = try #require(
            sqliteCreateTableSQL(definition: definition(foreignKeys: [foreignKey(name: "fk_child")]))
        )
        #expect(sql.contains("CONSTRAINT `fk_child` FOREIGN KEY (`parent_id`)"))
    }

    @Test("no referenced columns means no empty parentheses")
    func omittedReferencedColumns() throws {
        let sql = try #require(
            sqliteCreateTableSQL(definition: definition(foreignKeys: [foreignKey(referencedColumns: [])]))
        )
        #expect(sql.contains("REFERENCES `parent`"))
        #expect(!sql.contains("REFERENCES `parent` ()"))
    }

    @Test("referential actions are written only when they are not NO ACTION")
    func referentialActions() throws {
        let key = foreignKey(onDelete: "CASCADE", onUpdate: "SET NULL")
        let sql = try #require(sqliteCreateTableSQL(definition: definition(foreignKeys: [key])))
        #expect(sql.contains("ON DELETE CASCADE"))
        #expect(sql.contains("ON UPDATE SET NULL"))

        let plain = try #require(sqliteCreateTableSQL(definition: definition(foreignKeys: [foreignKey()])))
        #expect(!plain.contains("ON DELETE"))
        #expect(!plain.contains("ON UPDATE"))
    }

    @Test("a composite foreign key lists every column")
    func compositeForeignKey() throws {
        let columns = [
            PluginColumnDefinition(name: "a", dataType: "INTEGER"),
            PluginColumnDefinition(name: "b", dataType: "INTEGER")
        ]
        let key = PluginForeignKeyDefinition(
            name: "", columns: ["a", "b"], referencedTable: "parent", referencedColumns: ["x", "y"]
        )
        let sql = try #require(
            sqliteCreateTableSQL(definition: definition(columns: columns, foreignKeys: [key]))
        )
        #expect(sql.contains("FOREIGN KEY (`a`, `b`) REFERENCES `parent` (`x`, `y`)"))
    }

    @Test("a primary key named only by primaryKeyColumns still reaches the DDL")
    func primaryKeyColumnsAreHonoured() throws {
        let columns = [
            PluginColumnDefinition(name: "id", dataType: "INTEGER", autoIncrement: true),
            PluginColumnDefinition(name: "parent_id", dataType: "INTEGER")
        ]
        let sql = try #require(
            sqliteCreateTableSQL(definition: definition(columns: columns, primaryKeyColumns: ["id"]))
        )
        #expect(sql.contains("`id` INTEGER PRIMARY KEY AUTOINCREMENT"))
    }

    @Test("a composite primary key becomes a table constraint")
    func compositePrimaryKey() throws {
        let columns = [
            PluginColumnDefinition(name: "a", dataType: "INTEGER", isPrimaryKey: true),
            PluginColumnDefinition(name: "b", dataType: "INTEGER", isPrimaryKey: true)
        ]
        let sql = try #require(sqliteCreateTableSQL(definition: definition(columns: columns)))
        #expect(sql.contains("PRIMARY KEY (`a`, `b`)"))
    }

    @Test("no columns produces no statement")
    func emptyColumns() {
        #expect(sqliteCreateTableSQL(definition: definition(columns: [])) == nil)
    }

    @Test("an identifier carrying a backtick is escaped")
    func escapedIdentifier() throws {
        let columns = [PluginColumnDefinition(name: "we`ird", dataType: "TEXT")]
        let sql = try #require(sqliteCreateTableSQL(definition: definition(columns: columns)))
        #expect(sql.contains("`we``ird`"))
    }

    /// A unique partial index that loses its predicate rejects rows the user meant to exclude, so
    /// the condition is part of the index rather than decoration.
    @Test("a partial index keeps its WHERE predicate")
    func partialIndex() {
        let index = PluginIndexDefinition(
            name: "idx_open", columns: ["parent_id"], isUnique: true, whereClause: "deleted_at IS NULL"
        )
        #expect(
            sqliteAddIndexSQL(table: "child", index: index)
                == "CREATE UNIQUE INDEX `idx_open` ON `child` (`parent_id`) WHERE deleted_at IS NULL"
        )
    }

    @Test("an index is its own statement")
    func addIndex() {
        let index = PluginIndexDefinition(name: "idx_parent", columns: ["parent_id"], isUnique: true)
        #expect(
            sqliteAddIndexSQL(table: "child", index: index)
                == "CREATE UNIQUE INDEX `idx_parent` ON `child` (`parent_id`)"
        )
    }
}
