//
//  MSSQLTableDefinitionSQLTests.swift
//  TableProTests
//
//  The CREATE TABLE the SQL Server driver writes for a copied or new table.
//

import Foundation
import TableProPluginKit
import Testing

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
        #expect(MSSQLTableDefinitionSQL.createTableStatements(
            PluginCreateTableDefinition(tableName: "orders", columns: []), schema: "dbo"
        ) == nil)
    }

    // MARK: - Descriptions

    private static func commented(_ name: String, _ comment: String?) -> PluginColumnDefinition {
        PluginColumnDefinition(name: name, dataType: "INT", isNullable: true, comment: comment)
    }

    @Test("Create Table writes each column description after the table and its indexes")
    func createTableStatementsCarryColumnDescriptions() throws {
        let statements = try #require(MSSQLTableDefinitionSQL.createTableStatements(
            PluginCreateTableDefinition(
                tableName: "orders",
                columns: [Self.commented("id", "The key"), Self.commented("note", nil), Self.commented("x", "")],
                indexes: [Self.index("ix_note", ["note"], type: nil)]
            ),
            schema: "dbo"
        ))
        #expect(statements == [
            "CREATE TABLE [dbo].[orders] (\n  [id] INT NULL,\n  [note] INT NULL,\n  [x] INT NULL\n)",
            "CREATE INDEX [ix_note] ON [dbo].[orders] ([note])",
            "EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The key', "
                + "@level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'orders', "
                + "@level2type = N'COLUMN', @level2name = N'id'",
        ])
    }

    /// An older app sends this text whole, so it stays the table and its indexes only.
    @Test("The single Create Table text carries no description")
    func createTableTextLeavesDescriptionsOut() throws {
        let sql = try #require(Self.createTable(columns: [Self.commented("id", "The key")], indexes: []))
        #expect(sql == "CREATE TABLE [dbo].[orders] (\n  [id] INT NULL\n);")
    }

    @Test("A table comment updates the description when it exists and adds it when it does not")
    func tableCommentUpserts() {
        let sql = MSSQLTableDefinitionSQL.commentStatement(
            objectType: "TABLE", schema: "dbo", object: "orders", comment: "Placed orders"
        )
        let target = "@level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'orders'"
        #expect(sql == """
            IF EXISTS (SELECT 1 FROM sys.fn_listextendedproperty(N'MS_Description', N'SCHEMA', N'dbo', \
            N'TABLE', N'orders', NULL, NULL))
                EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Placed orders', \(target)
            ELSE
                EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Placed orders', \(target)
            """)
    }

    @Test("A view comment names the view level")
    func viewCommentUsesTheViewLevel() throws {
        let sql = try #require(MSSQLTableDefinitionSQL.commentStatement(
            objectType: "VIEW", schema: "sales", object: "v", comment: "c"
        ))
        #expect(sql.contains("N'SCHEMA', N'sales', N'VIEW', N'v', NULL, NULL"))
        #expect(sql.contains("@level1type = N'VIEW', @level1name = N'v'"))
        #expect(!sql.contains("N'TABLE'"))
    }

    @Test("A nil or empty comment drops the description only when there is one")
    func emptyCommentDrops() {
        let expected = """
            IF EXISTS (SELECT 1 FROM sys.fn_listextendedproperty(N'MS_Description', N'SCHEMA', N'dbo', \
            N'TABLE', N'orders', NULL, NULL))
                EXEC sys.sp_dropextendedproperty @name = N'MS_Description', @level0type = N'SCHEMA', \
            @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'orders'
            """
        for comment in [nil, ""] as [String?] {
            let sql = MSSQLTableDefinitionSQL.commentStatement(
                objectType: "TABLE", schema: "dbo", object: "orders", comment: comment
            )
            #expect(sql == expected)
        }
    }

    @Test("Other kinds cannot be commented", arguments: ["MATERIALIZED VIEW", "SYSTEM TABLE", "SEQUENCE"])
    func otherKindsHaveNoCommentStatement(kind: String) {
        #expect(MSSQLTableDefinitionSQL.commentStatement(objectType: kind, schema: "s", object: "t", comment: nil) == nil)
    }

    @Test("Names and the comment are N literals with their quotes doubled")
    func descriptionLiteralsAreEscaped() throws {
        let sql = try #require(MSSQLTableDefinitionSQL.commentStatement(
            objectType: "TABLE", schema: "o'neil", object: "it's", comment: "日本'語"
        ))
        #expect(sql.contains("N'SCHEMA', N'o''neil', N'TABLE', N'it''s', NULL, NULL"))
        #expect(sql.contains("@value = N'日本''語'"))
        #expect(!sql.contains("N'o'neil'"))
    }

    @Test("A view description is read from the view level")
    func viewDescriptionQuery() {
        #expect(MSSQLTableDefinitionSQL.descriptionQuery(schema: "dbo", objectKind: "VIEW", object: "v")
            == "SELECT CAST(value AS NVARCHAR(MAX)) FROM sys.fn_listextendedproperty(N'MS_Description', "
            + "N'SCHEMA', N'dbo', N'VIEW', N'v', NULL, NULL)")
    }
}
