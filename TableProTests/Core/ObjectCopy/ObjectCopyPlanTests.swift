//
//  ObjectCopyPlanTests.swift
//  TableProTests
//
//  What the plan promises the runner and the review pane, which is where
//  emptying a table and refilling it have to agree.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class ObjectCopyPlanTests: XCTestCase {
    private func endpoint(
        _ database: String,
        schema: String? = nil,
        connectionId: UUID = UUID()
    ) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: database, schema: schema),
            connectionName: "server",
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    private func request(
        content: ObjectCopyContent = .data,
        existingPolicy: ObjectCopyExistingPolicy = .replace,
        errorHandling: ImportErrorHandling = .stopAndRollback,
        wrapEachTableInTransaction: Bool = true,
        destination: ObjectCopyDestination? = nil
    ) -> ObjectCopyRequest {
        ObjectCopyRequest(
            source: endpoint("app"),
            destination: destination ?? .existing(endpoint("staging")),
            objects: [],
            content: content,
            existingPolicy: existingPolicy,
            errorHandling: errorHandling,
            wrapEachTableInTransaction: wrapEachTableInTransaction
        )
    }

    private func statement(_ sql: String, _ object: String) -> SyncStatement {
        SyncStatement(sql: sql, objectName: object, summary: sql)
    }

    private func step(
        _ name: String,
        copiesData: Bool = true,
        truncates: Bool = true
    ) -> ObjectCopyTableStep {
        ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: name, schema: "public"),
            dropStatements: [],
            sequenceStatements: [],
            createStatements: [],
            truncateStatements: truncates ? [statement("DELETE FROM \(name);", name)] : [],
            columns: copiesData ? ["id"] : [],
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT \"id\" FROM \"\(name)\"",
            targetTable: name,
            targetSchema: "public",
            estimatedRows: nil,
            copiesData: copiesData,
            copiesIdentityColumn: false,
            note: nil
        )
    }

    private func plan(
        _ steps: [ObjectCopyTableStep],
        request: ObjectCopyRequest? = nil,
        schemaStatements: [SyncStatement] = []
    ) -> ObjectCopyPlan {
        ObjectCopyPlan(
            request: request ?? self.request(),
            createsDatabase: false,
            tableSteps: steps,
            definitionSteps: [],
            schemaStatements: schemaStatements
        )
    }

    /// The defect this suite exists for. A table with no writable column in common is not in
    /// `dataSteps`, so clearing it deleted every row the target had and wrote nothing back, while
    /// the review said only that the two sides shared no writable column.
    func testATableThatCopiesNoRowsIsNeverEmptied() {
        let copied = step("orders")
        let unwritable = step("legacy_audit", copiesData: false)

        let cleared = plan([copied, unwritable]).clearGroups.map(\.selection.name)

        XCTAssertEqual(cleared, ["orders"])
    }

    /// Children first, so the first parent DELETE does not meet child rows a cascading key would
    /// take out of a table the user never selected.
    func testTablesAreEmptiedChildrenFirst() {
        let cleared = plan([step("customers"), step("orders")]).clearGroups.map(\.selection.name)

        XCTAssertEqual(cleared, ["orders", "customers"])
    }

    /// Emptying a table is reversible only while the transaction that emptied it is still open, so
    /// a run that promises a rollback cannot put its DELETEs in a phase of their own.
    func testAPromisedRollbackKeepsTheClearsInsideTheDataTransaction() {
        XCTAssertTrue(plan([step("orders")]).clearsInsideDataTransaction)
    }

    func testARunThatPromisesNoRollbackClearsAhead() {
        XCTAssertFalse(plan(
            [step("orders")],
            request: request(errorHandling: .skipAndContinue)
        ).clearsInsideDataTransaction)
        XCTAssertFalse(plan(
            [step("orders")],
            request: request(wrapEachTableInTransaction: false)
        ).clearsInsideDataTransaction)
    }

    /// Nothing to empty means nothing to promise, and the per-table transactions stay.
    func testACopyWithNothingToEmptyKeepsItsPerTableTransactions() {
        XCTAssertFalse(plan([step("orders", truncates: false)]).clearsInsideDataTransaction)
    }

    /// The script is what the user approves, so it has to be in the order the run uses. Shown
    /// against each table instead, it said the parent was emptied after the child had been filled.
    func testTheScriptEmptiesEveryTableBeforeItReadsAny() {
        let script = plan([step("customers"), step("orders")]).scriptText
        let lines = script.components(separatedBy: "\n").filter { !$0.isEmpty }

        guard let lastDelete = lines.lastIndex(where: { $0.hasPrefix("DELETE FROM") }),
              let firstSelect = lines.firstIndex(where: { $0.hasPrefix("SELECT") }) else {
            return XCTFail("the script named neither the clears nor the reads:\n\(script)")
        }
        XCTAssertLessThan(lastDelete, firstSelect)
        /// Children first there too, or the script and the run disagree about the cascade.
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("DELETE FROM") },
            ["DELETE FROM orders;", "DELETE FROM customers;"]
        )
    }

    /// A new database carries only whatever schema its engine gives it, so the rest are created
    /// before the first `CREATE TABLE` names one.
    func testSchemaStatementsLeadTheScriptAndTheDDL() {
        let create = statement("CREATE SCHEMA IF NOT EXISTS \"sales\";", "sales")
        let built = plan([step("orders", truncates: false)], schemaStatements: [create])

        XCTAssertEqual(built.ddlStatements.first?.sql, create.sql)
        XCTAssertTrue(built.scriptText.hasPrefix(create.sql))
    }

    /// One object fails once per phase it reaches, so a table whose CREATE failed under Skip and
    /// Continue fails again in the data phase. Listed by the selection's id a SwiftUI `ForEach` saw
    /// a duplicate identifier and dropped one of the two messages.
    func testEveryFailureKeepsAnIdentityOfItsOwn() {
        let selection = ObjectCopySelection(kind: .table, name: "orders", schema: "public")
        let result = ObjectCopyRunResult(
            outcomes: [
                ObjectCopyObjectOutcome(selection: selection, rowsCopied: 0, error: "syntax error"),
                ObjectCopyObjectOutcome(selection: selection, rowsCopied: 0, error: "does not exist")
            ],
            rowsCopied: 0,
            cancelled: false,
            createdDatabase: nil
        )

        let failures = result.failures
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(Set(failures.map(\.id)).count, 2)
        XCTAssertEqual(failures.map(\.outcome.error), ["syntax error", "does not exist"])
        /// The summary still counts the object once, which is the reason the ids had to collide.
        XCTAssertEqual(result.failedCount, 1)
    }
}
