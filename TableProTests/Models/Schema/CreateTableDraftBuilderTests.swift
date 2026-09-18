//
//  CreateTableDraftBuilderTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProPluginKit

@testable import TablePro

@MainActor
@Suite("Create Table draft builder")
struct CreateTableDraftBuilderTests {
    private func column(
        _ name: String,
        _ type: String = "INTEGER",
        primaryKey: Bool = false,
        autoIncrement: Bool = false
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: type, isNullable: true, defaultValue: nil,
            autoIncrement: autoIncrement, unsigned: false, comment: nil, collation: nil,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: primaryKey
        )
    }

    private func foreignKey(
        name: String = "",
        columns: [String] = ["parent_id"],
        referencedTable: String = "parent",
        referencedColumns: [String] = ["id"],
        referencedSchema: String? = nil,
        onDelete: EditableForeignKeyDefinition.ReferentialAction = .noAction,
        onUpdate: EditableForeignKeyDefinition.ReferentialAction = .noAction
    ) -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(), name: name, columns: columns, referencedTable: referencedTable,
            referencedColumns: referencedColumns, referencedSchema: referencedSchema,
            onDelete: onDelete, onUpdate: onUpdate
        )
    }

    private func index(name: String = "idx", columns: [String] = ["parent_id"]) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: false,
            isPrimary: false, comment: nil, columnPrefixes: [:], whereClause: nil
        )
    }

    private func plan(
        columns: [EditableColumnDefinition] = [],
        indexes: [EditableIndexDefinition] = [],
        foreignKeys: [EditableForeignKeyDefinition] = [],
        databaseType: DatabaseType = .sqlite,
        tableName: String = "child"
    ) -> CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: tableName,
            options: CreateTableOptions(),
            columns: columns.isEmpty ? [column("id"), column("parent_id")] : columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            dialect: ForeignKeyDialect.forType(databaseType),
            includesEngineOptions: false
        )
    }

    // MARK: - The reported bug

    @Test("a foreign key with no constraint name is emitted")
    func unnamedForeignKeyIsEmitted() throws {
        let result = plan(foreignKeys: [foreignKey(name: "")])
        #expect(result.issues.isEmpty)
        let definition = try #require(result.definition)
        #expect(definition.foreignKeys.count == 1)
        #expect(definition.foreignKeys.first?.name == "")
    }

    @Test("a named foreign key keeps its name")
    func namedForeignKeyKeepsName() throws {
        let result = plan(foreignKeys: [foreignKey(name: "fk_child_parent")])
        let definition = try #require(result.definition)
        #expect(definition.foreignKeys.first?.name == "fk_child_parent")
    }

    @Test("an index with no name is reported, not dropped")
    func unnamedIndexIsReported() {
        let result = plan(indexes: [index(name: "")])
        #expect(result.indexes.isEmpty)
        #expect(result.issues.contains { $0.tab == .indexes })
        #expect(!result.isReadyToCreate)
    }

    @Test("a named index survives")
    func namedIndexSurvives() {
        let result = plan(indexes: [index(name: "idx_parent")])
        #expect(result.issues.isEmpty)
        #expect(result.indexes.map(\.name) == ["idx_parent"])
    }

    // MARK: - Blank rows stay silent

    @Test("an untouched foreign key row raises nothing")
    func blankForeignKeyIsIgnored() {
        let blank = EditableForeignKeyDefinition.placeholder()
        let result = plan(foreignKeys: [blank])
        #expect(result.issues.isEmpty)
        #expect(result.definition?.foreignKeys.isEmpty == true)
    }

    @Test("an untouched index row raises nothing")
    func blankIndexIsIgnored() {
        let result = plan(indexes: [EditableIndexDefinition.placeholder()])
        #expect(result.issues.isEmpty)
        #expect(result.indexes.isEmpty)
    }

    @Test("a blank extra column row raises nothing")
    func blankColumnIsIgnored() {
        let result = plan(columns: [column("id"), EditableColumnDefinition.placeholder()])
        #expect(result.issues.isEmpty)
        #expect(result.definition?.columns.count == 1)
    }

    // MARK: - Incomplete rows are reported

    @Test("a foreign key with no referenced table is reported")
    func missingReferencedTableIsReported() {
        let result = plan(foreignKeys: [foreignKey(referencedTable: "")])
        #expect(result.issues.contains { $0.tab == .foreignKeys })
        #expect(result.definition?.foreignKeys.isEmpty == true)
    }

    @Test("a foreign key naming a column the table lacks is reported")
    func unknownColumnIsReported() {
        let result = plan(foreignKeys: [foreignKey(columns: ["nope"])])
        #expect(result.issues.contains { $0.tab == .foreignKeys })
    }

    @Test("mismatched composite column counts are reported")
    func compositeArityMismatchIsReported() {
        let result = plan(
            columns: [column("id"), column("a"), column("b")],
            foreignKeys: [foreignKey(columns: ["a", "b"], referencedColumns: ["id"])]
        )
        #expect(result.issues.contains { $0.tab == .foreignKeys })
    }

    @Test("a duplicate column name is reported")
    func duplicateColumnIsReported() {
        let result = plan(columns: [column("id"), column("id")])
        #expect(result.issues.contains { $0.tab == .columns })
    }

    @Test("a table with no name is reported")
    func missingTableNameIsReported() {
        let result = plan(tableName: "  ")
        #expect(result.definition == nil)
        #expect(result.issues.contains { $0.row == nil })
    }

    // MARK: - Referenced columns and the dialect

    @Test("SQLite accepts a foreign key with no referenced columns")
    func sqliteAllowsOmittedReferencedColumns() throws {
        let result = plan(foreignKeys: [foreignKey(referencedColumns: [])], databaseType: .sqlite)
        #expect(result.issues.isEmpty)
        let definition = try #require(result.definition)
        #expect(definition.foreignKeys.first?.referencedColumns.isEmpty == true)
    }

    @Test("MySQL reports a foreign key with no referenced columns")
    func mysqlRequiresReferencedColumns() {
        let result = plan(foreignKeys: [foreignKey(referencedColumns: [])], databaseType: .mysql)
        #expect(result.issues.contains { $0.tab == .foreignKeys })
    }

    @Test("DuckDB reports ON DELETE CASCADE")
    func duckdbRejectsCascade() {
        let result = plan(foreignKeys: [foreignKey(onDelete: .cascade)], databaseType: .duckdb)
        #expect(result.issues.contains { $0.tab == .foreignKeys })
    }

    @Test("SQLite accepts ON DELETE CASCADE")
    func sqliteAcceptsCascade() {
        let result = plan(foreignKeys: [foreignKey(onDelete: .cascade)], databaseType: .sqlite)
        #expect(result.issues.isEmpty)
    }

    @Test("SQLite reports a referenced table in another schema")
    func sqliteRejectsQualifiedReference() {
        let result = plan(foreignKeys: [foreignKey(referencedSchema: "other")], databaseType: .sqlite)
        #expect(result.issues.contains { $0.tab == .foreignKeys })
    }

    /// Every foreign key starts at `.noAction`, and Oracle, Dameng and Teradata declare an empty
    /// `updateActions` because they have no `ON UPDATE` grammar. Reading NO ACTION as a listed
    /// action rejected every foreign key on those three engines.
    @Test("an engine with no ON UPDATE grammar still accepts a default foreign key")
    func engineWithoutOnUpdateAcceptsDefaults() throws {
        for type in [DatabaseType.oracle, .dameng, .teradata] {
            let result = plan(foreignKeys: [foreignKey()], databaseType: type)
            #expect(result.issues.isEmpty, "\(type.rawValue) rejected a foreign key with default actions")
            #expect(result.definition?.foreignKeys.count == 1)
        }
    }

    /// The duplicate is reported against the grid row the user is looking at. Reporting the position
    /// in the compacted list points at whatever row happened to survive the skip before it.
    @Test("a duplicate name is reported against its own grid row")
    func duplicateReportsTheGridRow() {
        let result = plan(columns: [
            column("id"),
            column("", ""),
            column("only_a_name", ""),
            column("id")
        ])
        let duplicate = result.issues.first { $0.message.contains("already named") }
        #expect(duplicate?.row == 3)
    }

    @Test("the created name is trimmed")
    func tableNameIsTrimmed() throws {
        let result = plan(tableName: "  spaced  ")
        let definition = try #require(result.definition)
        #expect(definition.tableName == "spaced")
    }

    // MARK: - Primary key reconciliation

    @Test("an auto-increment column with no primary key tick becomes the primary key")
    func autoIncrementImpliesPrimaryKey() throws {
        let result = plan(columns: [column("id", autoIncrement: true), column("parent_id")])
        let definition = try #require(result.definition)
        #expect(definition.primaryKeyColumns == ["id"])
        #expect(definition.columns.first?.isPrimaryKey == true)
    }

    @Test("an explicit primary key is left alone")
    func explicitPrimaryKeyWins() throws {
        let result = plan(columns: [column("id", primaryKey: true), column("parent_id", autoIncrement: true)])
        let definition = try #require(result.definition)
        #expect(definition.primaryKeyColumns == ["id"])
    }

    // MARK: - Indexes never ride inside the CREATE TABLE

    @Test("indexes are kept out of the table definition")
    func indexesAreSeparate() throws {
        let result = plan(indexes: [index(name: "idx_parent")])
        let definition = try #require(result.definition)
        #expect(definition.indexes.isEmpty)
        #expect(result.indexes.count == 1)
    }
}
