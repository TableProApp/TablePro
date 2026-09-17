//
//  MSSQLTableDefinitionSQLTests.swift
//  TableProTests
//
//  The CREATE TABLE the SQL Server driver writes for a copied or new table.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL Server table definition")
struct MSSQLTableDefinitionSQLTests {
    private static func column(_ name: String, primaryKey: Bool = false) -> PluginColumnDefinition {
        PluginColumnDefinition(name: name, dataType: "INT", isNullable: !primaryKey, isPrimaryKey: primaryKey)
    }

    private static func index(_ name: String, _ columns: [String], type: String?) -> PluginIndexDefinition {
        PluginIndexDefinition(name: name, columns: columns, indexType: type)
    }

    private static func createTable(
        columns: [PluginColumnDefinition],
        indexes: [PluginIndexDefinition]
    ) -> String? {
        MSSQLTableDefinitionSQL.createTable(
            PluginCreateTableDefinition(tableName: "orders", columns: columns, indexes: indexes),
            schema: "dbo"
        )
    }

    /// A table holds one clustered index and a primary key is clustered unless it says otherwise, so
    /// the copied `CLUSTERED` index would be refused with "Cannot create more than one clustered index".
    @Test("A single-column key is written NONCLUSTERED when another index is CLUSTERED")
    func inlineKeyYieldsToAClusteredIndex() {
        let sql = Self.createTable(
            columns: [Self.column("id", primaryKey: true), Self.column("placed_at")],
            indexes: [Self.index("ix_placed", ["placed_at"], type: "CLUSTERED")]
        )
        #expect(sql == """
            CREATE TABLE [dbo].[orders] (
              [id] INT NOT NULL PRIMARY KEY NONCLUSTERED,
              [placed_at] INT NULL
            );

            CREATE CLUSTERED INDEX [ix_placed] ON [dbo].[orders] ([placed_at]);
            """)
    }

    @Test("A composite key is written NONCLUSTERED when another index is CLUSTERED")
    func compositeKeyYieldsToAClusteredIndex() throws {
        let sql = try #require(Self.createTable(
            columns: [Self.column("a", primaryKey: true), Self.column("b", primaryKey: true), Self.column("c")],
            indexes: [Self.index("ix_c", ["c"], type: "clustered")]
        ))
        #expect(sql.contains("  PRIMARY KEY NONCLUSTERED ([a], [b])"))
        #expect(!sql.contains("[a] INT NOT NULL PRIMARY KEY"))
    }

    @Test("Without a CLUSTERED index the key keeps the server's default")
    func keyStaysDefaultWithoutAClusteredIndex() throws {
        let sql = try #require(Self.createTable(
            columns: [Self.column("id", primaryKey: true), Self.column("placed_at")],
            indexes: [
                Self.index("ix_placed", ["placed_at"], type: "NONCLUSTERED"),
                Self.index("ix_other", ["placed_at"], type: "BTREE")
            ]
        ))
        #expect(sql.contains("[id] INT NOT NULL PRIMARY KEY,"))
        #expect(!sql.contains("NONCLUSTERED,"))
        #expect(sql.contains("CREATE NONCLUSTERED INDEX [ix_placed] ON [dbo].[orders] ([placed_at])"))
        #expect(sql.contains("CREATE INDEX [ix_other] ON [dbo].[orders] ([placed_at])"))
    }

    @Test("A column added to an existing table never carries a key clause")
    func addedColumnHasNoKeyClause() {
        #expect(MSSQLTableDefinitionSQL.columnDefinition(Self.column("id", primaryKey: true), inlinePrimaryKey: nil)
            == "[id] INT NOT NULL")
    }

    @Test("A table with no columns writes nothing")
    func emptyTableWritesNothing() {
        #expect(Self.createTable(columns: [], indexes: []) == nil)
    }
}
