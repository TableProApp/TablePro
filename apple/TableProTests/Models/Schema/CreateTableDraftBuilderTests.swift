//
//  CreateTableDraftBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
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

    private func check(_ name: String, _ expression: String) -> EditableCheckConstraintDefinition {
        EditableCheckConstraintDefinition(id: UUID(), name: name, expression: expression, columns: [], isValidated: true)
    }

    private func plan(
        columns: [EditableColumnDefinition] = [],
        indexes: [EditableIndexDefinition] = [],
        foreignKeys: [EditableForeignKeyDefinition] = [],
        checkConstraints: [EditableCheckConstraintDefinition] = [],
        databaseType: DatabaseType = .sqlite,
        tableName: String = "child"
    ) -> CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: tableName,
            options: CreateTableOptions(),
            columns: columns.isEmpty ? [column("id"), column("parent_id")] : columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            checkConstraints: checkConstraints,
            dialect: ForeignKeyDialect.forType(databaseType),
            includesEngineOptions: false
        )
    }

    // MARK: - Engines that key every row themselves

    private func namedOnlyPlan(suppliesItsOwnKey: Bool) -> CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: "events",
            options: CreateTableOptions(),
            columns: [column("", "")],
            indexes: [],
            foreignKeys: [],
            dialect: ForeignKeyDialect.forType(.sqlite),
            includesEngineOptions: false,
            suppliesItsOwnKey: suppliesItsOwnKey
        )
    }

    @Test("A table with only a name is planned on an engine that supplies its own key")
    func nameOnlyTableOnAnEngineWithItsOwnKey() throws {
        let result = namedOnlyPlan(suppliesItsOwnKey: true)
        #expect(result.issues.isEmpty)
        let definition = try #require(result.definition)
        #expect(definition.tableName == "events")
        #expect(definition.columns.isEmpty)
    }

    @Test("A table with only a name still needs a column everywhere else")
    func nameOnlyTableNeedsAColumnOtherwise() {
        let result = namedOnlyPlan(suppliesItsOwnKey: false)
        #expect(result.definition == nil)
        #expect(!result.issues.isEmpty)
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
        #expect(result.issues.contains { $0.section == .indexes })
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
        #expect(result.issues.contains { $0.section == .foreignKeys })
        #expect(result.definition?.foreignKeys.isEmpty == true)
    }

    @Test("a foreign key naming a column the table lacks is reported")
    func unknownColumnIsReported() {
        let result = plan(foreignKeys: [foreignKey(columns: ["nope"])])
        #expect(result.issues.contains { $0.section == .foreignKeys })
    }

    @Test("mismatched composite column counts are reported")
    func compositeArityMismatchIsReported() {
        let result = plan(
            columns: [column("id"), column("a"), column("b")],
            foreignKeys: [foreignKey(columns: ["a", "b"], referencedColumns: ["id"])]
        )
        #expect(result.issues.contains { $0.section == .foreignKeys })
    }

    @Test("a duplicate column name is reported")
    func duplicateColumnIsReported() {
        let result = plan(columns: [column("id"), column("id")])
        #expect(result.issues.contains { $0.section == .columns })
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
        #expect(result.issues.contains { $0.section == .foreignKeys })
    }

    @Test("DuckDB reports ON DELETE CASCADE")
    func duckdbRejectsCascade() {
        let result = plan(foreignKeys: [foreignKey(onDelete: .cascade)], databaseType: .duckdb)
        #expect(result.issues.contains { $0.section == .foreignKeys })
    }

    @Test("SQLite accepts ON DELETE CASCADE")
    func sqliteAcceptsCascade() {
        let result = plan(foreignKeys: [foreignKey(onDelete: .cascade)], databaseType: .sqlite)
        #expect(result.issues.isEmpty)
    }

    @Test("SQLite reports a referenced table in another schema")
    func sqliteRejectsQualifiedReference() {
        let result = plan(foreignKeys: [foreignKey(referencedSchema: "other")], databaseType: .sqlite)
        #expect(result.issues.contains { $0.section == .foreignKeys })
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

    @Test("an auto-increment column made the primary key drops a NULL default with its nullability")
    func promotedPrimaryKeyDropsNullDefault() throws {
        var id = column("id", autoIncrement: true)
        id.defaultValue = "NULL"
        let result = plan(columns: [id, column("parent_id")])
        let definition = try #require(result.definition)
        #expect(definition.columns.first?.isNullable == false)
        #expect(definition.columns.first?.defaultValue == nil)
    }

    @Test("a NOT NULL column with a NULL default is reported rather than sent")
    func notNullColumnWithNullDefaultIsReported() {
        var name = column("name", "VARCHAR(255)")
        name.isNullable = false
        name.defaultValue = "NULL"
        let result = plan(columns: [column("id", primaryKey: true), name])
        #expect(result.issues.contains { $0.row == 1 })
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

    // MARK: - Table comment

    private func plan(comment: String) -> CreateTablePlan {
        var options = CreateTableOptions()
        options.comment = comment
        return CreateTableDraftBuilder.plan(
            tableName: "child",
            options: options,
            columns: [column("id")],
            indexes: [],
            foreignKeys: [],
            dialect: ForeignKeyDialect.forType(.postgresql),
            includesEngineOptions: false
        )
    }

    @Test("the plan carries the typed comment as typed")
    func planCarriesTheComment() {
        #expect(plan(comment: "Child rows").tableComment == "Child rows")
        #expect(plan(comment: "line one\nline two").tableComment == "line one\nline two")
    }

    @Test("a blank comment plans no comment", arguments: ["", "   ", "\n\t"])
    func blankCommentIsNil(comment: String) {
        #expect(plan(comment: comment).tableComment == nil)
    }

    // MARK: - Table options against the target database's defaults

    private static let shopDefaults = CreateTableOptionDefaults(
        characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci", engine: "InnoDB"
    )

    private func plan(
        options: CreateTableOptions,
        defaults: CreateTableOptionDefaults = CreateTableDraftBuilderTests.shopDefaults,
        includesEngineOptions: Bool = true
    ) throws -> PluginCreateTableDefinition {
        try #require(CreateTableDraftBuilder.plan(
            tableName: "child",
            options: options,
            columns: [column("id")],
            indexes: [],
            foreignKeys: [],
            dialect: ForeignKeyDialect.forType(.mysql),
            includesEngineOptions: includesEngineOptions,
            defaults: defaults
        ).definition)
    }

    // A fresh draft used to write `DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`, which broke FKs and joins
    // against every table that took the database's own default.
    @Test("A fresh draft names no character set, collation or engine")
    func freshDraftWritesNoOptions() throws {
        let definition = try plan(options: CreateTableOptions())
        #expect(definition.charset == nil)
        #expect(definition.collation == nil)
        #expect(definition.engine == nil)
    }

    @Test("Options equal to the database's defaults write no clause")
    func defaultsWriteNothing() throws {
        let seeded = CreateTableOptions().seeded(with: Self.shopDefaults)
        #expect(seeded.charset == "utf8mb4")
        let definition = try plan(options: seeded)
        #expect(definition.charset == nil)
        #expect(definition.collation == nil)
        #expect(definition.engine == nil)
    }

    @Test("Another character set writes the pair")
    func otherCharacterSetWritesThePair() throws {
        let options = CreateTableOptions().selectingCharacterSet("latin1", collation: "latin1_swedish_ci")
        let definition = try plan(options: options)
        #expect(definition.charset == "latin1")
        #expect(definition.collation == "latin1_swedish_ci")
    }

    @Test("Another collation of the default set still writes both clauses")
    func otherCollationWritesThePair() throws {
        let options = CreateTableOptions().selectingCharacterSet("utf8mb4", collation: "utf8mb4_bin")
        let definition = try plan(options: options)
        #expect(definition.charset == "utf8mb4")
        #expect(definition.collation == "utf8mb4_bin")
    }

    @Test("The comparison ignores case, as the server does")
    func comparisonIgnoresCase() throws {
        let options = CreateTableOptions().selectingCharacterSet("UTF8MB4", collation: "UTF8MB4_0900_AI_CI")
        #expect(try plan(options: options).charset == nil)
    }

    @Test("Only an engine other than the server's default is written")
    func engineOnlyWhenItDiffers() throws {
        var options = CreateTableOptions().seeded(with: Self.shopDefaults)
        #expect(try plan(options: options).engine == nil)
        options.engine = "MyISAM"
        #expect(try plan(options: options).engine == "MyISAM")
    }

    @Test("Without the database's defaults every pick is written")
    func unknownDefaultsWriteThePick() throws {
        let options = CreateTableOptions().selectingCharacterSet("utf8mb4", collation: "utf8mb4_0900_ai_ci")
        let definition = try plan(options: options, defaults: CreateTableOptionDefaults())
        #expect(definition.charset == "utf8mb4")
        #expect(definition.collation == "utf8mb4_0900_ai_ci")
    }

    @Test("A driver without a catalog gets no table options, whatever the draft holds")
    func noCatalogWritesNothing() throws {
        var options = CreateTableOptions().selectingCharacterSet("latin1", collation: "latin1_bin")
        options.engine = "MyISAM"
        let definition = try plan(options: options, includesEngineOptions: false)
        #expect(definition.charset == nil)
        #expect(definition.collation == nil)
        #expect(definition.engine == nil)
    }

    @Test("Seeding keeps what the user already picked")
    func seedingKeepsPicks() {
        var options = CreateTableOptions().selectingCharacterSet("latin1", collation: "latin1_bin")
        options.engine = "MyISAM"
        let seeded = options.seeded(with: Self.shopDefaults)
        #expect(seeded.charset == "latin1")
        #expect(seeded.collation == "latin1_bin")
        #expect(seeded.engine == "MyISAM")
    }

    // MARK: - Check constraints

    @Test("A named check with an expression is planned, trimmed, after the CREATE")
    func completeCheckIsPlanned() {
        let result = plan(checkConstraints: [check(" positive_id ", " id > 0\n")])
        #expect(result.issues.isEmpty)
        #expect(result.checkConstraints.map { $0.name } == ["positive_id"])
        #expect(result.checkConstraints.map { $0.expression } == ["id > 0"])
    }

    @Test("A blank check row is ignored")
    func blankCheckIsIgnored() {
        let result = plan(checkConstraints: [check("", "  ")])
        #expect(result.issues.isEmpty)
        #expect(result.checkConstraints.isEmpty)
    }

    @Test("A begun check names what it lacks on its own row", arguments: [("", "id > 0"), ("positive_id", "")])
    func incompleteCheckIsReported(name: String, expression: String) {
        let result = plan(checkConstraints: [check("", ""), check(name, expression)])
        #expect(result.checkConstraints.isEmpty)
        #expect(result.issues.map { $0.section } == [.checkConstraints])
        #expect(result.issues.first?.row == 1)
        #expect(!result.isReadyToCreate)
    }

    @Test("A second check with the same name is flagged on its own row")
    func duplicateCheckNameIsReported() {
        let result = plan(checkConstraints: [check("positive", "id > 0"), check("", ""), check("positive", "id < 9")])
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.section == .checkConstraints)
        #expect(result.issues.first?.row == 2)
    }

    @Test("Planned indexes and checks keep the working rows they came from")
    func plannedRowsMapToWorkingRows() {
        let result = plan(
            indexes: [index(name: "", columns: []), index(name: "idx_parent")],
            checkConstraints: [check("", ""), check("", ""), check("positive", "id > 0")]
        )
        #expect(result.indexRows == [1])
        #expect(result.indexRow(at: 0) == 1)
        #expect(result.checkConstraintRows == [2])
        #expect(result.checkConstraintRow(at: 0) == 2)
    }
}
