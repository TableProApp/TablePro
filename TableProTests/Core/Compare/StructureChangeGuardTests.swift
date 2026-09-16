//
//  StructureChangeGuardTests.swift
//  TableProTests
//

import Foundation
import XCTest

@testable import TablePro

final class StructureChangeGuardTests: XCTestCase {
    private func column(
        _ name: String,
        _ dataType: String = "int",
        comment: String? = nil,
        collation: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: dataType, isNullable: true, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: comment, collation: collation,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
        )
    }

    private func snapshot(
        columns: [EditableColumnDefinition],
        collation: String? = nil
    ) -> TableStructureSnapshot {
        TableStructureSnapshot(name: "orders", schema: "shop", columns: columns, collation: collation)
    }

    private func table(
        status: TableDiffStatus = .differs,
        changes: [SchemaChange] = []
    ) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .table, schema: "shop", name: "orders"),
            status: status,
            changes: changes
        )
    }

    private func view(definition: [String]) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .view, schema: "shop", name: "recent_orders"),
            status: .onlyInSource,
            sourceDefinition: definition
        )
    }

    private func inputs(
        _ results: [CompareObjectResult],
        action: TableSyncAction,
        snapshot: TableStructureSnapshot? = nil
    ) -> [String: StructureGenerationInput] {
        StructureChangeGuard.inputs(
            for: results,
            actions: { _ in action },
            sourceSnapshots: snapshot.map { ["shop.orders": $0] } ?? [:]
        )
    }

    // MARK: - Alter

    func testAnAlterWhoseChangesStillMatchIsAllowed() {
        let result = table(changes: [.addColumn(column("total"))])

        XCTAssertNil(
            StructureChangeGuard.refusal(
                expected: inputs([result], action: .alter),
                actual: inputs([result], action: .alter)
            )
        )
    }

    func testAnAlterWhoseChangeListMovedIsRefused() {
        let expected = inputs([table(changes: [.addColumn(column("total"))])], action: .alter)
        let actual = inputs([table(changes: [.addColumn(column("total", "decimal(10,2)"))])], action: .alter)

        XCTAssertNotNil(StructureChangeGuard.refusal(expected: expected, actual: actual))
    }

    // MARK: - Create

    /// `SchemaSyncScriptBuilder` renders the snapshot raw, so the guard has to compare it raw. Two
    /// tables the comparison calls identical under its own options still produce different DDL.
    func testACreateWhoseSnapshotDiffersOnlyByCollationIsRefused() {
        let result = table(status: .onlyInSource)
        let expected = inputs([result], action: .create, snapshot: snapshot(columns: [column("id")]))
        let actual = inputs(
            [result], action: .create, snapshot: snapshot(columns: [column("id")], collation: "utf8mb4_bin")
        )

        XCTAssertNotNil(StructureChangeGuard.refusal(expected: expected, actual: actual))
    }

    func testACreateWhoseSnapshotDiffersOnlyByAColumnCommentIsRefused() {
        let result = table(status: .onlyInSource)
        let expected = inputs([result], action: .create, snapshot: snapshot(columns: [column("id")]))
        let actual = inputs(
            [result], action: .create, snapshot: snapshot(columns: [column("id", comment: "the key")])
        )

        XCTAssertNotNil(StructureChangeGuard.refusal(expected: expected, actual: actual))
    }

    func testACreateWhoseSourceTableIsGoneIsRefused() {
        let result = table(status: .onlyInSource)
        let expected = inputs([result], action: .create, snapshot: snapshot(columns: [column("id")]))

        XCTAssertNotNil(
            StructureChangeGuard.refusal(expected: expected, actual: inputs([result], action: .create))
        )
    }

    // MARK: - Drop

    func testADropOfATableThatCameBackIsRefused() {
        let expected = inputs([table(status: .onlyInTarget)], action: .drop)
        let actual = inputs([table(status: .differs)], action: .drop)

        XCTAssertNotNil(StructureChangeGuard.refusal(expected: expected, actual: actual))
    }

    func testADropOfATableThatIsNoLongerInTheReportIsRefused() {
        let expected = inputs([table(status: .onlyInTarget)], action: .drop)

        XCTAssertNotNil(StructureChangeGuard.refusal(expected: expected, actual: [:]))
    }

    // MARK: - Source-defined objects

    /// `SourceObjectSyncBuilder` writes `sourceDefinition` verbatim, while the comparison reads it
    /// through a normalizer that lowercases the body. A guard built on the normalized text would
    /// pass a stale CREATE VIEW for an edit that only changed a literal's case.
    func testAViewBodyDifferingOnlyInTheCaseOfALiteralIsRefused() {
        let expected = inputs([view(definition: ["SELECT 'Paid' AS state"])], action: .create)
        let actual = inputs([view(definition: ["SELECT 'PAID' AS state"])], action: .create)

        XCTAssertNotNil(StructureChangeGuard.refusal(expected: expected, actual: actual))
    }

    func testAnUnchangedViewIsAllowed() {
        let result = view(definition: ["SELECT 1"])

        XCTAssertNil(
            StructureChangeGuard.refusal(
                expected: inputs([result], action: .create),
                actual: inputs([result], action: .create)
            )
        )
    }

    // MARK: - Scope of the check

    func testAnObjectTheUserSkippedIsNotChecked() {
        let expected = StructureChangeGuard.inputs(
            for: [table(changes: [.addColumn(column("total"))])],
            actions: { _ in .skip },
            sourceSnapshots: [:]
        )

        XCTAssertTrue(expected.isEmpty)
        XCTAssertNil(StructureChangeGuard.refusal(expected: expected, actual: [:]))
    }

    /// Another table moving in the same schema is somebody else's work. Refusing on it would make a
    /// busy database impossible to sync.
    func testAnObjectOutsideTheSelectionDoesNotRefuse() {
        let selected = table(changes: [.addColumn(column("total"))])
        let other = CompareObjectResult(
            identity: CompareObjectIdentity(kind: .table, schema: "shop", name: "customers"),
            status: .differs,
            changes: [.addColumn(column("email"))]
        )
        var actual = inputs([selected], action: .alter)
        actual.merge(inputs([other], action: .alter)) { first, _ in first }

        XCTAssertNil(
            StructureChangeGuard.refusal(expected: inputs([selected], action: .alter), actual: actual)
        )
    }

    func testTheRefusalNamesTheObject() {
        let refusal = StructureChangeGuard.refusal(
            expected: inputs([table(changes: [.addColumn(column("total"))])], action: .alter),
            actual: [:]
        )

        let message = try? XCTUnwrap(refusal?.errorDescription)
        XCTAssertTrue(
            message?.contains("shop.orders") ?? false,
            "the message must name what changed, got \(message ?? "nil")"
        )
    }
}
