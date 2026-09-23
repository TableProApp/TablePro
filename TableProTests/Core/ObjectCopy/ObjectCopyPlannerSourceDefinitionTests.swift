//
//  ObjectCopyPlannerSourceDefinitionTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class ObjectCopyPlannerSourceDefinitionTests: XCTestCase {
    private let postgres = SQLScriptText(databaseType: .postgresql)

    private func read(_ source: String, failure: String? = nil) -> RoutineSourceRead {
        RoutineSourceRead(name: "recent", kind: .view, schema: "public", signature: nil, source: source, failure: failure)
    }

    private let view = ObjectCopySelection(kind: .view, name: "recent", schema: "public")
    private let function = ObjectCopySelection(kind: .function, name: "total", schema: "public", signature: "(integer)")
    private let trigger = ObjectCopySelection(kind: .trigger, name: "stamped", schema: "public", owner: "orders")

    // MARK: - Outcome

    func testAnUnreadableDefinitionIsSkippedWithTheDriversReason() {
        let reason = PluginObjectSourceError.insufficientPrivilege("recent").errorDescription ?? ""

        XCTAssertEqual(
            ObjectCopyPlanner.definitionOutcome(read("", failure: reason), sentAs: postgres),
            .skipped(reason)
        )
    }

    func testAnEmptyOrMissingDefinitionIsSkippedAsHavingNone() {
        XCTAssertEqual(ObjectCopyPlanner.definitionOutcome(nil, sentAs: postgres), .skipped(ObjectCopyPlanner.noDefinition))
        XCTAssertEqual(
            ObjectCopyPlanner.definitionOutcome(read("  \n "), sentAs: postgres),
            .skipped(ObjectCopyPlanner.noDefinition)
        )
        XCTAssertEqual(
            ObjectCopyPlanner.definitionOutcome(read("-- nothing"), sentAs: postgres),
            .skipped(ObjectCopyPlanner.noDefinition)
        )
    }

    func testABareBodyIsSkippedAsNotExecutable() {
        XCTAssertEqual(
            ObjectCopyPlanner.definitionOutcome(read("SELECT id, name FROM orders"), sentAs: postgres),
            .skipped(ObjectCopyEligibility.definitionNotExecutableRefusal)
        )
    }

    func testACreateStatementIsRunnableBehindALeadingComment() {
        let lowercase = "\n  create or replace view recent AS SELECT 1"
        let commented = "-- Author: ops\n/* audit */\nCREATE VIEW dbo.recent AS SELECT 1"

        XCTAssertEqual(ObjectCopyPlanner.definitionOutcome(read(lowercase), sentAs: postgres), .runnable(lowercase))
        XCTAssertEqual(
            ObjectCopyPlanner.definitionOutcome(read(commented), sentAs: SQLScriptText(databaseType: .mssql)),
            .runnable(commented)
        )
    }

    // MARK: - Reads

    func testAFailedRoutineListingSkipsTheRoutinesAndKeepsTheRest() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.viewDefinitions = ["recent": .success("CREATE VIEW recent AS SELECT 1")]
        driver.routines = .failure(DefinitionReadStubError(message: "permission denied for pg_proc"))

        let reads = try await ObjectCopyPlanner.sourceDefinitionReads(
            for: [view, function],
            views: [PluginTableInfo(name: "recent", type: "VIEW", schema: "public", comment: nil)],
            triggerTables: [],
            schema: "public",
            endpointName: "Local / app / public",
            using: driver
        )

        XCTAssertEqual(
            ObjectCopyPlanner.definitionOutcome(reads[view.id], sentAs: postgres),
            .runnable("CREATE VIEW recent AS SELECT 1")
        )
        guard case .skipped(let reason) = ObjectCopyPlanner.definitionOutcome(reads[function.id], sentAs: postgres) else {
            return XCTFail("a routine whose listing failed must be skipped")
        }
        XCTAssertTrue(reason.contains("permission denied for pg_proc"), reason)
    }

    func testAFailedTriggerListingSkipsTheTriggers() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.tableTriggers = ["orders": .failure(DefinitionReadStubError(message: "TRIGGER command denied"))]

        let reads = try await ObjectCopyPlanner.sourceDefinitionReads(
            for: [trigger],
            views: [],
            triggerTables: ["orders"],
            schema: "public",
            endpointName: "Local / app / public",
            using: driver
        )

        guard case .skipped(let reason) = ObjectCopyPlanner.definitionOutcome(reads[trigger.id], sentAs: postgres) else {
            return XCTFail("a trigger whose listing failed must be skipped")
        }
        XCTAssertTrue(reason.contains("TRIGGER command denied"), reason)
    }

    func testARoutineWhoseDDLIsRefusedIsSkippedWithTheDriversReason() async throws {
        let driver = SourceDefinitionStubDriver()
        let refusal = PluginObjectSourceError.insufficientPrivilege("total")
        driver.routines = .success([
            PluginRoutineInfo(name: "total", kind: .function, schema: "public", argumentSignature: "(integer)")
        ])
        driver.routineDDL = ["total": .failure(refusal)]

        let reads = try await ObjectCopyPlanner.sourceDefinitionReads(
            for: [function],
            views: [],
            triggerTables: [],
            schema: "public",
            endpointName: "Local / app / public",
            using: driver
        )

        XCTAssertEqual(
            ObjectCopyPlanner.definitionOutcome(reads[function.id], sentAs: postgres),
            .skipped(refusal.errorDescription ?? "")
        )
    }

    func testACancelledListingCancelsThePlan() async {
        let driver = SourceDefinitionStubDriver()
        driver.routines = .failure(CancellationError())

        do {
            _ = try await ObjectCopyPlanner.sourceDefinitionReads(
                for: [function],
                views: [],
                triggerTables: [],
                schema: "public",
                endpointName: "Local / app / public",
                using: driver
            )
            XCTFail("a cancelled plan must not turn into skipped objects")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
