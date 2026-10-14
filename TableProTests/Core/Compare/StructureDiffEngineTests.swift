//
//  StructureDiffEngineTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct StructureDiffEngineTests {
    private func column(
        _ name: String,
        _ dataType: String = "int",
        nullable: Bool = true,
        defaultValue: String? = nil,
        autoIncrement: Bool = false,
        comment: String? = nil,
        collation: String? = nil,
        charset: String? = nil,
        extra: String? = nil,
        primaryKey: Bool = false
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: nullable,
            defaultValue: defaultValue,
            autoIncrement: autoIncrement,
            unsigned: false,
            comment: comment,
            collation: collation,
            onUpdate: nil,
            charset: charset,
            extra: extra,
            isPrimaryKey: primaryKey
        )
    }

    private func index(
        _ name: String,
        columns: [String],
        unique: Bool = false,
        primary: Bool = false
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            type: .btree,
            isUnique: unique,
            isPrimary: primary,
            comment: nil,
            columnPrefixes: [:],
            whereClause: nil
        )
    }

    private func foreignKey(
        _ name: String,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String]
    ) -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            referencedTable: referencedTable,
            referencedColumns: referencedColumns,
            referencedSchema: nil,
            onDelete: .noAction,
            onUpdate: .noAction
        )
    }

    private func table(
        _ name: String,
        columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition] = [],
        foreignKeys: [EditableForeignKeyDefinition] = [],
        engine: String? = nil,
        collation: String? = nil
    ) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: name,
            schema: nil,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            engine: engine,
            charset: nil,
            collation: collation
        )
    }

    // MARK: - Table presence

    @Test
    func tableOnlyInSourceIsCreateAndDefaultsToSkip() {
        let engine = StructureDiffEngine()
        let report = engine.compare(
            source: [table("users", columns: [column("id")])],
            target: []
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].status == .onlyInSource)
        #expect(report.results[0].suggestedAction == .create)
    }

    @Test
    func tableOnlyInTargetIsDrop() {
        let engine = StructureDiffEngine()
        let report = engine.compare(
            source: [],
            target: [table("legacy", columns: [column("id")])]
        )

        #expect(report.results[0].status == .onlyInTarget)
        #expect(report.results[0].suggestedAction == .drop)
    }

    @Test
    func identicalTablesReportIdentical() {
        let engine = StructureDiffEngine()
        let source = table("users", columns: [column("id"), column("name", "varchar(20)")])
        let target = table("users", columns: [column("id"), column("name", "varchar(20)")])

        let result = engine.compareTable(source: source, target: target)

        #expect(result.status == .identical)
        #expect(result.changes.isEmpty)
    }

    // MARK: - Column changes, direction is target becomes source

    @Test
    func missingColumnInTargetProducesAddColumn() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id"), column("email", "varchar(255)")]),
            target: table("users", columns: [column("id")])
        )

        #expect(result.status == .differs)
        guard case .addColumn(let added) = result.changes.first else {
            Issue.record("Expected addColumn, got \(result.changes)")
            return
        }
        #expect(added.name == "email")
    }

    @Test
    func extraColumnInTargetProducesDeleteColumn() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id")]),
            target: table("users", columns: [column("id"), column("obsolete")])
        )

        guard case .deleteColumn(let removed) = result.changes.first else {
            Issue.record("Expected deleteColumn, got \(result.changes)")
            return
        }
        #expect(removed.name == "obsolete")
    }

    @Test
    func modifyColumnCarriesTargetAsOldAndSourceAsNew() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id", "bigint")]),
            target: table("users", columns: [column("id", "int")])
        )

        guard case .modifyColumn(let old, let new) = result.changes.first else {
            Issue.record("Expected modifyColumn, got \(result.changes)")
            return
        }
        #expect(old.dataType == "int", "old must be the target's current state")
        #expect(new.dataType == "bigint", "new must be the source's desired state")
    }

    @Test
    func nullabilityChangeIsDetected() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id", nullable: false)]),
            target: table("users", columns: [column("id", nullable: true)])
        )

        #expect(result.status == .differs)
        #expect(result.changes.count == 1)
    }

    // MARK: - Ignore options each kill a named false positive

    @Test
    func identifierCaseOnlyDifferenceIsIgnoredByDefault() {
        let result = StructureDiffEngine().compareTable(
            source: table("Users", columns: [column("ID")]),
            target: table("users", columns: [column("id")])
        )

        #expect(result.status == .identical)
    }

    @Test
    func identifierCaseDifferenceIsReportedWhenOptionOff() {
        var options = StructureCompareOptions()
        options.ignoreIdentifierCase = false
        let result = StructureDiffEngine(options: options).compareTable(
            source: table("users", columns: [column("ID")]),
            target: table("users", columns: [column("id")])
        )

        #expect(result.status == .differs)
    }

    @Test
    func autoIncrementSeedOnlyDifferenceIsIgnoredByDefault() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("id", extra: "auto_increment=1522")]),
            target: table("users", columns: [column("id", extra: "auto_increment=184")])
        )

        #expect(result.status == .identical, "AUTO_INCREMENT drift must not be a difference")
    }

    @Test
    func whitespaceOnlyDefaultDifferenceIsIgnoredByDefault() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("flag", defaultValue: "0")]),
            target: table("users", columns: [column("flag", defaultValue: "  0  ")])
        )

        #expect(result.status == .identical)
    }

    @Test
    func nullDefaultOnANullableColumnMatchesNoDefault() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("nickname", defaultValue: "NULL")]),
            target: table("users", columns: [column("nickname")])
        )

        #expect(result.status == .identical)
    }

    @Test
    func nullDefaultOnANotNullColumnIsStillADifference() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("nickname", nullable: false, defaultValue: "NULL")]),
            target: table("users", columns: [column("nickname", nullable: false)])
        )

        #expect(result.status != .identical)
    }

    @Test
    func collationOnlyDifferenceIsIgnoredByDefaultAndReportedWhenOptionOff() {
        let source = table("users", columns: [column("name", "varchar(20)", collation: "utf8mb4_general_ci")])
        let target = table("users", columns: [column("name", "varchar(20)", collation: "utf8mb4_unicode_ci")])

        #expect(StructureDiffEngine().compareTable(source: source, target: target).status == .identical)

        var options = StructureCompareOptions()
        options.ignoreCollationAndCharset = false
        #expect(StructureDiffEngine(options: options).compareTable(source: source, target: target).status == .differs)
    }

    @Test
    func commentOnlyDifferenceIsIgnoredByDefaultAndReportedWhenOptionOff() {
        let source = table("users", columns: [column("id", comment: "primary id")])
        let target = table("users", columns: [column("id", comment: nil)])

        #expect(StructureDiffEngine().compareTable(source: source, target: target).status == .identical)

        var options = StructureCompareOptions()
        options.ignoreCommentsAndOwners = false
        #expect(StructureDiffEngine(options: options).compareTable(source: source, target: target).status == .differs)
    }

    @Test
    func columnOrderIsIgnoredByDefaultAndNotedWhenOptionOff() {
        let source = table("users", columns: [column("a"), column("b")])
        let target = table("users", columns: [column("b"), column("a")])

        #expect(StructureDiffEngine().compareTable(source: source, target: target).status == .identical)

        var options = StructureCompareOptions()
        options.ignoreColumnOrder = false
        let result = StructureDiffEngine(options: options).compareTable(source: source, target: target)
        #expect(result.status == .differs)
        #expect(result.changes.isEmpty, "reordering emits no DDL")
        #expect(result.notes.count == 1)
    }

    // MARK: - Name-only differences never mark an object changed

    @Test
    func indexMatchedOnStructureDespiteGeneratedNameDifference() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("email")], indexes: [index("idx_a1b2", columns: ["email"])]),
            target: table("users", columns: [column("email")], indexes: [index("idx_c3d4", columns: ["email"])])
        )

        #expect(result.changes.isEmpty, "a name-only index difference must emit no DDL")
        #expect(result.notes.count == 1)
    }

    @Test
    func indexColumnDifferenceIsARealChange() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("a"), column("b")], indexes: [index("i", columns: ["a", "b"])]),
            target: table("users", columns: [column("a"), column("b")], indexes: [index("i", columns: ["a"])])
        )

        #expect(result.changes.count == 2, "expected one add and one delete")
    }

    @Test
    func foreignKeyMatchedOnStructureDespiteNameDifference() {
        let source = table(
            "orders",
            columns: [column("user_id")],
            foreignKeys: [foreignKey("fk_1", columns: ["user_id"], referencedTable: "users", referencedColumns: ["id"])]
        )
        let target = table(
            "orders",
            columns: [column("user_id")],
            foreignKeys: [foreignKey("fk_2", columns: ["user_id"], referencedTable: "users", referencedColumns: ["id"])]
        )

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        #expect(result.changes.isEmpty)
        #expect(result.notes.count == 1)
    }

    // MARK: - Primary key

    @Test
    func primaryKeyDifferenceProducesSingleModifyPrimaryKey() {
        let source = table("users", columns: [column("id", primaryKey: true), column("tenant", primaryKey: true)])
        let target = table("users", columns: [column("id", primaryKey: true), column("tenant")])

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        let primaryKeyChanges = result.changes.filter {
            if case .modifyPrimaryKey = $0 { return true }
            return false
        }
        #expect(primaryKeyChanges.count == 1)
        guard case .modifyPrimaryKey(let old, let new) = primaryKeyChanges[0] else {
            Issue.record("Expected modifyPrimaryKey")
            return
        }
        #expect(old == ["id"])
        #expect(new == ["id", "tenant"])
    }

    @Test
    func primaryKeyMembershipAloneDoesNotAlsoEmitModifyColumn() {
        let source = table("users", columns: [column("id", primaryKey: true)])
        let target = table("users", columns: [column("id", primaryKey: false)])

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        let columnChanges = result.changes.filter {
            if case .modifyColumn = $0 { return true }
            return false
        }
        #expect(columnChanges.isEmpty, "primary key membership is reported once, via modifyPrimaryKey")
    }

    // MARK: - Symmetry

    @Test
    func comparisonIsSymmetricInTheObjectsItReports() {
        let engine = StructureDiffEngine()
        let left = [table("a", columns: [column("id")]), table("b", columns: [column("id")])]
        let right = [table("b", columns: [column("id")]), table("c", columns: [column("id")])]

        let forward = engine.compare(source: left, target: right)
        let backward = engine.compare(source: right, target: left)

        #expect(forward.count(of: .onlyInSource) == backward.count(of: .onlyInTarget))
        #expect(forward.count(of: .onlyInTarget) == backward.count(of: .onlyInSource))
        #expect(forward.count(of: .identical) == backward.count(of: .identical))
    }
}
