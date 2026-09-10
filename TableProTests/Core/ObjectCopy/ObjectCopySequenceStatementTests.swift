//
//  ObjectCopySequenceStatementTests.swift
//  TableProTests
//
//  A copied table's default names its sequence, so the sequence has to exist
//  before the CREATE TABLE that references it runs.
//

@testable import TablePro
import XCTest

final class ObjectCopySequenceStatementTests: XCTestCase {
    /// The driver returns the create and the reposition as one block, and the runner sends one
    /// statement per `execute`, so the block has to arrive already split.
    func testAMultiStatementSequenceDDLBecomesOneStatementEach() {
        let statements = ObjectCopyPlanner.sequenceStatements(
            [
                "CREATE SEQUENCE \"orders_id_seq\" INCREMENT BY 1 MINVALUE 1 MAXVALUE 100 START WITH 1",
                "SELECT pg_catalog.setval('\"orders_id_seq\"', 42, true)"
            ],
            table: "orders"
        )
        XCTAssertEqual(statements.map(\.sql), [
            "CREATE SEQUENCE \"orders_id_seq\" INCREMENT BY 1 MINVALUE 1 MAXVALUE 100 START WITH 1;",
            "SELECT pg_catalog.setval('\"orders_id_seq\"', 42, true);"
        ])
    }

    func testAlreadyTerminatedSQLIsNotTerminatedTwice() {
        XCTAssertEqual(
            ObjectCopyPlanner.sequenceStatements(["CREATE SEQUENCE \"s\";"], table: "orders")
                .map(\.sql),
            ["CREATE SEQUENCE \"s\";"]
        )
    }

    /// Named after the table, because the progress list and the outcome report are both grouped by
    /// the object the user selected.
    func testTheStatementIsAttributedToTheTableThatNeedsIt() {
        let statement = ObjectCopyPlanner.sequenceStatements(
            ["CREATE SEQUENCE \"s\""], table: "orders"
        ).first
        XCTAssertEqual(statement?.objectName, "orders")
    }

    func testATableWithNoSequencesProducesNothing() {
        XCTAssertTrue(ObjectCopyPlanner.sequenceStatements([], table: "orders").isEmpty)
    }

    /// Ahead of the CREATE TABLE whose default references them, and behind the DROP that a
    /// replacement runs first.
    func testSequencesRunBeforeTheTableTheyBelongTo() {
        let step = ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: "orders", schema: "public"),
            dropStatements: [SyncStatement(sql: "DROP TABLE \"orders\";", objectName: "orders", summary: "")],
            sequenceStatements: ObjectCopyPlanner.sequenceStatements(
                ["CREATE SEQUENCE \"orders_id_seq\""], table: "orders"
            ),
            createStatements: [SyncStatement(sql: "CREATE TABLE \"orders\";", objectName: "orders", summary: "")],
            truncateStatements: [],
            columns: ["id"],
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT \"id\" FROM \"public\".\"orders\"",
            targetTable: "orders",
            targetSchema: "public",
            estimatedRows: nil,
            copiesData: false,
            copiesIdentityColumn: false,
            note: nil
        )
        XCTAssertEqual(step.ddl.map(\.sql), [
            "DROP TABLE \"orders\";",
            "CREATE SEQUENCE \"orders_id_seq\";",
            "CREATE TABLE \"orders\";"
        ])
    }
}
