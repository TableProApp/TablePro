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
            views: [
                TableStructureRead(
                    table: PluginTableInfo(name: "recent", type: "VIEW", schema: "public", comment: nil),
                    columns: [], indexes: [], foreignKeys: [], metadata: nil, failure: nil
                )
            ],
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

    // MARK: - A materialized view's indexes

    private let definition = "CREATE MATERIALIZED VIEW \"sales\".\"totals\" AS SELECT 1 AS id"

    private func input(
        schema: String = "sales",
        indexes: ObjectIndexRead?,
        targetCarries: Bool = true
    ) -> ObjectCopyDefinitionInput {
        ObjectCopyDefinitionInput(
            id: "totals",
            identity: CompareObjectIdentity(kind: .materializedView, schema: schema, name: "totals"),
            definition: definition,
            read: RoutineSourceRead(
                name: "totals", kind: .materializedView, schema: schema, signature: nil,
                source: definition, indexes: indexes
            ),
            targetCarriesIndexes: targetCarries,
            drop: nil
        )
    }

    private func builder(indexSchema: String) -> SourceObjectSyncBuilder {
        SourceObjectSyncBuilder(
            targetDriver: IndexStatementStubDriver(indexSchema: indexSchema),
            targetDatabaseType: .postgresql,
            indexSchema: indexSchema
        )
    }

    private let uniqueId = PluginIndexInfo(name: "totals_id_idx", columns: ["id"], isUnique: true)

    func testACopiedMaterializedViewGetsItsIndexesAfterItIsCreated() throws {
        let build = try ObjectCopyPlanner.definitionBuild(
            for: input(indexes: .read([uniqueId])), using: builder(indexSchema: "sales")
        )

        guard case .built(_, let create, let note) = build else { return XCTFail("expected statements, got \(build)") }
        XCTAssertEqual(create.map(\.sql), [
            definition,
            "CREATE UNIQUE INDEX \"totals_id_idx\" ON \"sales\".\"totals\" (\"id\")"
        ])
        XCTAssertNil(note)
    }

    /// A duplicated database is planned on the server's default database, so the index statements
    /// name its schema while the definition names the schema the view came from. Written anyway,
    /// they would index some other view of the same name or fail.
    func testADuplicatedDatabaseWhoseIndexesWouldLandInAnotherSchemaCopiesTheViewAndSaysSo() throws {
        let build = try ObjectCopyPlanner.definitionBuild(
            for: input(indexes: .read([uniqueId])), using: builder(indexSchema: "public")
        )

        guard case .built(_, let create, let note) = build else { return XCTFail("expected statements, got \(build)") }
        XCTAssertEqual(create.map(\.sql), [definition])
        XCTAssertEqual(note, SourceObjectIndexes.otherSchemaNote)
    }

    func testATargetThatTakesNoIndexesGetsTheViewAndANote() throws {
        let build = try ObjectCopyPlanner.definitionBuild(
            for: input(indexes: .read([uniqueId]), targetCarries: false), using: builder(indexSchema: "sales")
        )

        guard case .built(_, let create, let note) = build else { return XCTFail("expected statements, got \(build)") }
        XCTAssertEqual(create.map(\.sql), [definition])
        XCTAssertEqual(note, SourceObjectIndexes.notCarriedByTargetNote)
    }

    func testAViewWhoseIndexesCouldNotBeReadIsLeftOutWithTheReason() throws {
        let build = try ObjectCopyPlanner.definitionBuild(
            for: input(indexes: .failed("permission denied for pg_index")), using: builder(indexSchema: "sales")
        )

        guard case .refused(let reason) = build else { return XCTFail("expected a refusal, got \(build)") }
        XCTAssertTrue(reason.contains("permission denied for pg_index"), reason)
    }
}
