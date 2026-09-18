//
//  StructureDiffEngineTests.swift
//  TableProTests
//

import Foundation
import XCTest

@testable import TablePro

final class StructureDiffEngineTests: XCTestCase {
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

    func testTableOnlyInSourceIsCreateAndDefaultsToSkip() {
        let engine = StructureDiffEngine()
        let report = engine.compare(
            source: [table("users", columns: [column("id")])],
            target: []
        )

        XCTAssertEqual(report.results.count, 1)
        XCTAssertEqual(report.results[0].status, .onlyInSource)
        XCTAssertEqual(report.results[0].suggestedAction, .create)
    }

    func testTableOnlyInTargetIsDrop() {
        let engine = StructureDiffEngine()
        let report = engine.compare(
            source: [],
            target: [table("legacy", columns: [column("id")])]
        )

        XCTAssertEqual(report.results[0].status, .onlyInTarget)
        XCTAssertEqual(report.results[0].suggestedAction, .drop)
    }

    func testIdenticalTablesReportIdentical() {
        let engine = StructureDiffEngine()
        let source = table("users", columns: [column("id"), column("name", "varchar(20)")])
        let target = table("users", columns: [column("id"), column("name", "varchar(20)")])

        let result = engine.compareTable(source: source, target: target)

        XCTAssertEqual(result.status, .identical)
        XCTAssertTrue(result.changes.isEmpty)
    }

    // MARK: - Column changes, direction is target becomes source

    func testMissingColumnInTargetProducesAddColumn() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id"), column("email", "varchar(255)")]),
            target: table("users", columns: [column("id")])
        )

        XCTAssertEqual(result.status, .differs)
        guard case .addColumn(let added) = result.changes.first else {
            return XCTFail("Expected addColumn, got \(result.changes)")
        }
        XCTAssertEqual(added.name, "email")
    }

    func testExtraColumnInTargetProducesDeleteColumn() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id")]),
            target: table("users", columns: [column("id"), column("obsolete")])
        )

        guard case .deleteColumn(let removed) = result.changes.first else {
            return XCTFail("Expected deleteColumn, got \(result.changes)")
        }
        XCTAssertEqual(removed.name, "obsolete")
    }

    func testModifyColumnCarriesTargetAsOldAndSourceAsNew() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id", "bigint")]),
            target: table("users", columns: [column("id", "int")])
        )

        guard case .modifyColumn(let old, let new) = result.changes.first else {
            return XCTFail("Expected modifyColumn, got \(result.changes)")
        }
        XCTAssertEqual(old.dataType, "int", "old must be the target's current state")
        XCTAssertEqual(new.dataType, "bigint", "new must be the source's desired state")
    }

    func testNullabilityChangeIsDetected() {
        let engine = StructureDiffEngine()
        let result = engine.compareTable(
            source: table("users", columns: [column("id", nullable: false)]),
            target: table("users", columns: [column("id", nullable: true)])
        )

        XCTAssertEqual(result.status, .differs)
        XCTAssertEqual(result.changes.count, 1)
    }

    // MARK: - Ignore options each kill a named false positive

    func testIdentifierCaseOnlyDifferenceIsIgnoredByDefault() {
        let result = StructureDiffEngine().compareTable(
            source: table("Users", columns: [column("ID")]),
            target: table("users", columns: [column("id")])
        )

        XCTAssertEqual(result.status, .identical)
    }

    func testIdentifierCaseDifferenceIsReportedWhenOptionOff() {
        var options = StructureCompareOptions()
        options.ignoreIdentifierCase = false
        let result = StructureDiffEngine(options: options).compareTable(
            source: table("users", columns: [column("ID")]),
            target: table("users", columns: [column("id")])
        )

        XCTAssertEqual(result.status, .differs)
    }

    func testAutoIncrementSeedOnlyDifferenceIsIgnoredByDefault() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("id", extra: "auto_increment=1522")]),
            target: table("users", columns: [column("id", extra: "auto_increment=184")])
        )

        XCTAssertEqual(result.status, .identical, "AUTO_INCREMENT drift must not be a difference")
    }

    func testWhitespaceOnlyDefaultDifferenceIsIgnoredByDefault() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("flag", defaultValue: "0")]),
            target: table("users", columns: [column("flag", defaultValue: "  0  ")])
        )

        XCTAssertEqual(result.status, .identical)
    }

    func testCollationOnlyDifferenceIsIgnoredByDefaultAndReportedWhenOptionOff() {
        let source = table("users", columns: [column("name", "varchar(20)", collation: "utf8mb4_general_ci")])
        let target = table("users", columns: [column("name", "varchar(20)", collation: "utf8mb4_unicode_ci")])

        XCTAssertEqual(StructureDiffEngine().compareTable(source: source, target: target).status, .identical)

        var options = StructureCompareOptions()
        options.ignoreCollationAndCharset = false
        XCTAssertEqual(
            StructureDiffEngine(options: options).compareTable(source: source, target: target).status,
            .differs
        )
    }

    func testCommentOnlyDifferenceIsIgnoredByDefaultAndReportedWhenOptionOff() {
        let source = table("users", columns: [column("id", comment: "primary id")])
        let target = table("users", columns: [column("id", comment: nil)])

        XCTAssertEqual(StructureDiffEngine().compareTable(source: source, target: target).status, .identical)

        var options = StructureCompareOptions()
        options.ignoreCommentsAndOwners = false
        XCTAssertEqual(
            StructureDiffEngine(options: options).compareTable(source: source, target: target).status,
            .differs
        )
    }

    func testColumnOrderIsIgnoredByDefaultAndNotedWhenOptionOff() {
        let source = table("users", columns: [column("a"), column("b")])
        let target = table("users", columns: [column("b"), column("a")])

        XCTAssertEqual(StructureDiffEngine().compareTable(source: source, target: target).status, .identical)

        var options = StructureCompareOptions()
        options.ignoreColumnOrder = false
        let result = StructureDiffEngine(options: options).compareTable(source: source, target: target)
        XCTAssertEqual(result.status, .differs)
        XCTAssertTrue(result.changes.isEmpty, "reordering emits no DDL")
        XCTAssertEqual(result.notes.count, 1)
    }

    // MARK: - Name-only differences never mark an object changed

    func testIndexMatchedOnStructureDespiteGeneratedNameDifference() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("email")], indexes: [index("idx_a1b2", columns: ["email"])]),
            target: table("users", columns: [column("email")], indexes: [index("idx_c3d4", columns: ["email"])])
        )

        XCTAssertTrue(result.changes.isEmpty, "a name-only index difference must emit no DDL")
        XCTAssertEqual(result.notes.count, 1)
    }

    func testIndexColumnDifferenceIsARealChange() {
        let result = StructureDiffEngine().compareTable(
            source: table("users", columns: [column("a"), column("b")], indexes: [index("i", columns: ["a", "b"])]),
            target: table("users", columns: [column("a"), column("b")], indexes: [index("i", columns: ["a"])])
        )

        XCTAssertEqual(result.changes.count, 2, "expected one add and one delete")
    }

    func testForeignKeyMatchedOnStructureDespiteNameDifference() {
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

        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.notes.count, 1)
    }

    // MARK: - Primary key

    func testPrimaryKeyDifferenceProducesSingleModifyPrimaryKey() {
        let source = table("users", columns: [column("id", primaryKey: true), column("tenant", primaryKey: true)])
        let target = table("users", columns: [column("id", primaryKey: true), column("tenant")])

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        let primaryKeyChanges = result.changes.filter {
            if case .modifyPrimaryKey = $0 { return true }
            return false
        }
        XCTAssertEqual(primaryKeyChanges.count, 1)
        guard case .modifyPrimaryKey(let old, let new) = primaryKeyChanges[0] else {
            return XCTFail("Expected modifyPrimaryKey")
        }
        XCTAssertEqual(old, ["id"])
        XCTAssertEqual(new, ["id", "tenant"])
    }

    func testPrimaryKeyMembershipAloneDoesNotAlsoEmitModifyColumn() {
        let source = table("users", columns: [column("id", primaryKey: true)])
        let target = table("users", columns: [column("id", primaryKey: false)])

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        let columnChanges = result.changes.filter {
            if case .modifyColumn = $0 { return true }
            return false
        }
        XCTAssertTrue(columnChanges.isEmpty, "primary key membership is reported once, via modifyPrimaryKey")
    }

    // MARK: - Symmetry

    func testComparisonIsSymmetricInTheObjectsItReports() {
        let engine = StructureDiffEngine()
        let left = [table("a", columns: [column("id")]), table("b", columns: [column("id")])]
        let right = [table("b", columns: [column("id")]), table("c", columns: [column("id")])]

        let forward = engine.compare(source: left, target: right)
        let backward = engine.compare(source: right, target: left)

        XCTAssertEqual(forward.count(of: .onlyInSource), backward.count(of: .onlyInTarget))
        XCTAssertEqual(forward.count(of: .onlyInTarget), backward.count(of: .onlyInSource))
        XCTAssertEqual(forward.count(of: .identical), backward.count(of: .identical))
    }
}
