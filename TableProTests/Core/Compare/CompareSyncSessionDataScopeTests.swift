//
//  CompareSyncSessionDataScopeTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
private final class DataScopeConnectionList {
    var connections: [DatabaseConnection]

    init(_ connections: [DatabaseConnection]) {
        self.connections = connections
    }
}

@MainActor
final class CompareSyncSessionDataScopeTests: XCTestCase {
    private let sourceConnection = UUID()
    private let targetConnection = UUID()
    private let suiteName = "CompareSyncSessionDataScopeTests"
    private let failure = "Timed out reading the target."
    private var storage: CompareSyncProfileStorage?

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        storage = CompareSyncProfileStorage(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        storage = nil
        super.tearDown()
    }

    // MARK: - A scope edit clears only its own table's answer

    func testSettingKeyColumnsClearsOnlyThatTablesAnswer() throws {
        let session = try makeComparedSession()

        session.setKeyColumns(["email"], for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).keyColumns, ["email"])
        try assertAnswerCleared(on: "public.orders", keptOn: "public.users", in: session)
    }

    func testTogglingAComparedColumnClearsOnlyThatTablesAnswer() throws {
        let session = try makeComparedSession()

        session.toggleComparedColumn("email", for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).comparedColumns, ["updated_at"])
        try assertAnswerCleared(on: "public.orders", keptOn: "public.users", in: session)
    }

    func testSettingASourceFilterClearsOnlyThatTablesAnswer() throws {
        let session = try makeComparedSession()

        session.setSourceFilter("email LIKE '%@example.com'", for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).scope.sourceFilter, "email LIKE '%@example.com'")
        try assertAnswerCleared(on: "public.orders", keptOn: "public.users", in: session)
    }

    func testSplittingTheTargetFilterClearsOnlyThatTablesAnswer() throws {
        let session = try makeComparedSession()

        session.setUsesSameFilterForTarget(false, for: "public.orders")

        XCTAssertFalse(try plan("public.orders", in: session).scope.usesSameFilterForTarget)
        try assertAnswerCleared(on: "public.orders", keptOn: "public.users", in: session)
    }

    func testSettingARowLimitClearsOnlyThatTablesAnswer() throws {
        let session = try makeComparedSession()

        session.setRowLimit(500, for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).scope.rowLimit, 500)
        try assertAnswerCleared(on: "public.orders", keptOn: "public.users", in: session)
    }

    func testAnEditThatLeavesTheScopeAsItWasKeepsTheAnswer() throws {
        let session = try makeComparedSession()

        session.setSourceFilter("", for: "public.orders")
        session.setUsesSameFilterForTarget(true, for: "public.orders")

        let orders = try plan("public.orders", in: session)
        XCTAssertNotNil(orders.summary)
        XCTAssertEqual(orders.comparisonFailure, failure)
        XCTAssertEqual(orders.excludedRowKeys, ["1"])
    }

    // MARK: - Row exclusions

    func testChangingTheKeyClearsThatTablesRowExclusions() throws {
        let session = try makeComparedSession()

        session.setKeyColumns(["email"], for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, [])
        XCTAssertEqual(try plan("public.users", in: session).excludedRowKeys, ["1"])
    }

    func testChangingTheSourceFilterClearsThatTablesRowExclusions() throws {
        let session = try makeComparedSession()

        session.setSourceFilter("id > 10", for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, [])
        XCTAssertEqual(try plan("public.users", in: session).excludedRowKeys, ["1"])
    }

    func testChangingTheTargetFilterClearsThatTablesRowExclusions() throws {
        let session = try makeComparedSession()

        session.setTargetFilter("id > 10", for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, [])
    }

    /// A row exclusion is keyed on the row's identity, which only the key columns decide.
    func testTogglingAComparedColumnKeepsThatTablesRowExclusions() throws {
        let session = try makeComparedSession()

        session.toggleComparedColumn("email", for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, ["1"])
    }

    // MARK: - Filter validation

    func testASourceFilterWithASemicolonMakesTheTableUncomparable() throws {
        let session = try makeComparedSession()

        session.setSourceFilter("id = 1; DELETE FROM orders", for: "public.orders")

        let orders = try plan("public.orders", in: session)
        XCTAssertEqual(orders.unavailableReason, "A filter is a single condition and cannot contain a semicolon.")
        XCTAssertFalse(orders.isComparable)
    }

    func testCorrectingAnInvalidFilterMakesTheTableComparableAgain() throws {
        let session = try makeComparedSession()
        session.setSourceFilter("id = 1; DELETE FROM orders", for: "public.orders")

        session.setSourceFilter("id = 1", for: "public.orders")

        XCTAssertNil(try plan("public.orders", in: session).unavailableReason)
    }

    func testAnUnclosedParenthesisInTheTargetFilterMakesTheTableUncomparable() throws {
        let session = try makeComparedSession()

        session.setTargetFilter("(id > 1", for: "public.orders")

        let orders = try plan("public.orders", in: session)
        XCTAssertEqual(orders.unavailableReason, "A quote or parenthesis in this filter is not closed.")
        XCTAssertNil(try plan("public.users", in: session).unavailableReason)
    }

    // MARK: - Compared columns are per table

    func testTogglingAComparedColumnInOneTableLeavesAnotherTablesColumnsAlone() throws {
        let session = try makeComparedSession()

        session.toggleComparedColumn("email", for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).comparedColumns, ["updated_at"])
        XCTAssertEqual(try plan("public.users", in: session).comparedColumns, ["email", "updated_at"])
        XCTAssertFalse(session.isColumnCompared("email", in: "public.orders"))
        XCTAssertTrue(session.isColumnCompared("email", in: "public.users"))
    }

    func testTogglingAComparedColumnTwiceComparesItAgain() throws {
        let session = try makeComparedSession()

        session.toggleComparedColumn("email", for: "public.orders")
        session.toggleComparedColumn("email", for: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).comparedColumns, ["email", "updated_at"])
    }

    // MARK: - A sync in flight owns the setup

    func testTheSetupCannotChangeWhileASyncIsApplying() throws {
        let session = try makeComparedSession()
        XCTAssertTrue(session.canChangeSetup)

        session.activity = .applying

        XCTAssertFalse(session.canChangeSetup)
    }

    func testIncludingATableIsRefusedWhileApplying() throws {
        let session = try makeComparedSession()
        session.statements = [statement()]
        session.activity = .applying

        session.setPlanEnabled(false, for: "public.orders")

        XCTAssertTrue(try plan("public.orders", in: session).isEnabled)
        XCTAssertEqual(session.statements.count, 1, "the script being applied is not invalidated under it")
    }

    func testChangingAKeyIsRefusedWhileApplying() throws {
        let session = try makeComparedSession()
        session.activity = .applying

        session.setKeyColumns(["email"], for: "public.orders")

        let orders = try plan("public.orders", in: session)
        XCTAssertEqual(orders.keyColumns, ["id"])
        XCTAssertNotNil(orders.summary)
        XCTAssertEqual(orders.excludedRowKeys, ["1"])
    }

    func testExcludingARowIsRefusedWhileApplying() throws {
        let session = try makeComparedSession()
        session.statements = [statement()]
        session.activity = .applying

        session.setRowsIncluded(false, entries: [entry(.insert, key: "2")], planId: "public.orders")

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, ["1"])
        XCTAssertEqual(session.statements.count, 1)
    }

    func testSwappingEndpointsIsRefusedWhileApplying() throws {
        let session = try makeComparedSession()
        let source = endpoint(connectionId: sourceConnection, database: "prod")
        let target = endpoint(connectionId: targetConnection, database: "staging")
        session.source = source
        session.target = target
        session.activity = .applying

        session.swapEndpoints()

        XCTAssertEqual(session.source, source)
        XCTAssertEqual(session.target, target)
        XCTAssertEqual(session.dataPlans.count, 2, "a refused swap does not reset the comparison")
    }

    // MARK: - After a run

    /// A row the user refused was never written, so the refusal outlives the run that skipped it.
    func testMarkingAppliedKeepsEveryTickAndEveryRowExclusionAndDropsTheStatements() throws {
        let session = try makeSession()
        session.adoptDataPlans([
            makePlan(table: "orders", isEnabled: true, excludedRowKeys: ["1"]),
            makePlan(table: "users", isEnabled: false, excludedRowKeys: ["2"])
        ])
        session.statements = [statement()]

        session.markAppliedAndStale()

        XCTAssertTrue(try plan("public.orders", in: session).isEnabled)
        XCTAssertFalse(try plan("public.users", in: session).isEnabled)
        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, ["1"])
        XCTAssertEqual(try plan("public.users", in: session).excludedRowKeys, ["2"])
        XCTAssertTrue(session.statements.isEmpty)
        XCTAssertTrue(session.isStaleAfterApply)
    }

    // MARK: - Selected object count

    func testATableWhoseOnlyDifferencesAreDeletesCountsOnlyOnceDeletesAreWritten() throws {
        let session = try makeSession()
        session.mode = .data
        session.adoptDataPlans([makePlan(table: "orders", summary: makeSummary(deletes: ["7", "8"]))])

        session.dataOptions.deleteExtraRows = false
        XCTAssertEqual(session.selectedObjectCount, 0)

        session.dataOptions.deleteExtraRows = true
        XCTAssertEqual(session.selectedObjectCount, 1)
    }

    func testExcludingEveryRetainedRowTakesATableOutOfTheCount() throws {
        let session = try makeSession()
        session.mode = .data
        session.adoptDataPlans([makePlan(table: "orders", summary: makeSummary(inserts: ["1", "2"]))])

        session.setRowsIncluded(false, entries: [entry(.insert, key: "1")], planId: "public.orders")
        XCTAssertEqual(session.selectedObjectCount, 1)

        session.setRowsIncluded(false, entries: [entry(.insert, key: "2")], planId: "public.orders")
        XCTAssertEqual(session.selectedObjectCount, 0)
    }

    func testADisabledTableIsNotCounted() throws {
        let session = try makeSession()
        session.mode = .data
        session.adoptDataPlans([
            makePlan(table: "orders", isEnabled: false, summary: makeSummary(inserts: ["1"]))
        ])

        XCTAssertEqual(session.selectedObjectCount, 0)
    }

    // MARK: - Script blocker

    func testTheScriptBlockerNamesAnIncludedTableWithNoAnswer() throws {
        let session = try makeSession()
        session.mode = .data
        session.adoptDataPlans([
            makePlan(table: "orders", summary: makeSummary(inserts: ["1"])),
            makePlan(table: "users"),
            makePlan(table: "archive", isEnabled: false)
        ])

        XCTAssertEqual(
            session.dataScriptBlocker,
            "Compare again, or exclude the tables not compared yet: public.users."
        )
        XCTAssertTrue(session.needsRecompare)
    }

    func testTheScriptBlockerClearsOnceEveryIncludedTableHasAnAnswer() throws {
        let session = try makeSession()
        session.mode = .data
        session.adoptDataPlans([
            makePlan(table: "orders", summary: makeSummary(inserts: ["1"])),
            makePlan(table: "users", summary: makeSummary(updates: ["4"])),
            makePlan(table: "archive", isEnabled: false)
        ])

        XCTAssertNil(session.dataScriptBlocker)
        XCTAssertFalse(session.needsRecompare)
    }

    // MARK: - Status counts

    func testStatusCountsStayEmptyInDataModeUntilATableHasAnAnswer() throws {
        let session = try makeSession()
        session.mode = .data
        session.adoptDataPlans([makePlan(table: "orders"), makePlan(table: "users")])

        XCTAssertEqual(session.statusCounts, [])

        let index = try XCTUnwrap(session.dataPlans.firstIndex { $0.id == "public.orders" })
        session.dataPlans[index].summary = makeSummary(
            inserts: ["1", "2"], updates: ["3"], deletes: ["4"], identicalCount: 5
        )

        XCTAssertEqual(session.statusCounts, [
            CompareStatusCount(status: .onlyInSource, count: 2),
            CompareStatusCount(status: .differs, count: 1),
            CompareStatusCount(status: .onlyInTarget, count: 1),
            CompareStatusCount(status: .identical, count: 5)
        ])
    }

    // MARK: - Target write refusal

    /// The endpoint captured the level when the target was picked; the connection's current level wins.
    func testATargetWhoseConnectionIsNowReadOnlyIsRefused() throws {
        let list = DataScopeConnectionList([connection(id: targetConnection, name: "staging")])
        let session = try makeSession(connections: list)
        session.target = endpoint(connectionId: targetConnection, database: "staging", level: .silent)
        XCTAssertNil(session.targetWriteRefusal)

        list.connections[0].safeModeLevel = .readOnly

        let refusal = "Read-Only. Choose a different connection to write changes to."
        XCTAssertEqual(session.targetWriteRefusal, refusal)
        XCTAssertEqual(session.applyDisabledReason, refusal)
        XCTAssertFalse(session.canApply)
    }

    func testATargetCapturedReadOnlyWhoseConnectionNowAllowsWritesIsNotRefused() throws {
        let list = DataScopeConnectionList([connection(id: targetConnection, name: "staging")])
        let session = try makeSession(connections: list)

        session.target = endpoint(connectionId: targetConnection, database: "staging", level: .readOnly)

        XCTAssertNil(session.targetWriteRefusal)
    }

    func testATargetWithNoMatchingConnectionKeepsTheLevelItCaptured() throws {
        let session = try makeSession(connections: DataScopeConnectionList([]))

        session.target = endpoint(connectionId: targetConnection, database: "staging", level: .readOnly)

        XCTAssertEqual(session.targetWriteRefusal, "Read-Only. Choose a different connection to write changes to.")
    }

    // MARK: - Pending scopes

    func testAdoptingPlansAppliesAPendingScopeByTableId() throws {
        let session = try makeSession()
        session.pendingTableScopes = [
            "public.orders": DataTableScope(
                keyColumns: ["email"],
                excludedColumns: ["updated_at", "dropped_column"],
                sourceFilter: "id > 5",
                targetFilter: "id > 6",
                rowLimit: 50
            )
        ]

        session.adoptDataPlans([makePlan(table: "orders"), makePlan(table: "users")])

        let orders = try plan("public.orders", in: session)
        XCTAssertEqual(orders.keyColumns, ["email"])
        XCTAssertTrue(orders.scope.isExcluded("updated_at"))
        XCTAssertFalse(orders.scope.isExcluded("dropped_column"), "an exclusion is kept only for a column it has")
        XCTAssertEqual(orders.scope.sourceFilter, "id > 5")
        XCTAssertEqual(orders.scope.targetFilter, "id > 6")
        XCTAssertEqual(orders.scope.rowLimit, 50)
        XCTAssertEqual(try plan("public.users", in: session).scope, DataTableScope(keyColumns: ["id"]))
    }

    func testAPendingKeyNamingAMissingColumnFallsBackToTheTablesOwnKey() throws {
        let session = try makeSession()
        session.pendingTableScopes = [
            "public.orders": DataTableScope(keyColumns: ["email", "tenant_id"], sourceFilter: "id > 5")
        ]

        session.adoptDataPlans([makePlan(table: "orders")])

        let orders = try plan("public.orders", in: session)
        XCTAssertEqual(orders.keyColumns, ["id"])
        XCTAssertEqual(orders.scope.sourceFilter, "id > 5", "the rest of the pending scope still applies")
        XCTAssertTrue(orders.isComparable)
    }

    func testLegacyExclusionsApplyOnlyToTablesWithNoPendingScope() throws {
        let session = try makeSession()
        session.pendingTableScopes = ["public.orders": DataTableScope(keyColumns: ["id"], rowLimit: 10)]
        session.pendingLegacyExcludedColumns = ["updated_at"]

        session.adoptDataPlans([
            makePlan(table: "orders"),
            makePlan(table: "users"),
            makePlan(table: "tags", columns: ["id", "label"])
        ])

        XCTAssertFalse(try plan("public.orders", in: session).scope.isExcluded("updated_at"))
        XCTAssertTrue(try plan("public.users", in: session).scope.isExcluded("updated_at"))
        XCTAssertEqual(try plan("public.tags", in: session).scope, DataTableScope(keyColumns: ["id"]))
    }

    func testAdoptingPlansConsumesPendingScopesAndLegacyExclusions() throws {
        let session = try makeSession()
        session.pendingTableScopes = ["public.orders": DataTableScope(keyColumns: ["email"])]
        session.pendingLegacyExcludedColumns = ["updated_at"]

        session.adoptDataPlans([makePlan(table: "orders"), makePlan(table: "users")])

        XCTAssertTrue(session.pendingTableScopes.isEmpty)
        XCTAssertTrue(session.pendingLegacyExcludedColumns.isEmpty)
    }

    func testAPendingScopeThatChangesAPlanDropsTheAnswerItCarried() throws {
        let session = try makeSession()
        session.pendingTableScopes = ["public.orders": DataTableScope(keyColumns: ["email"])]

        session.adoptDataPlans([
            makePlan(table: "orders", summary: makeSummary(inserts: ["1"]), excludedRowKeys: ["1"])
        ])

        let orders = try plan("public.orders", in: session)
        XCTAssertNil(orders.summary)
        XCTAssertEqual(orders.excludedRowKeys, [])
    }

    // MARK: - Compared summaries

    func testACompareResultCarriesItsSummaryAndFailureOntoAnUnchangedPlan() throws {
        let session = try makeSession()
        session.adoptDataPlans([makePlan(table: "orders")])
        var run = makePlan(table: "orders", summary: makeSummary(inserts: ["1", "2"]))
        run.comparisonFailure = failure

        session.applyComparedSummaries(from: [run])

        let orders = try plan("public.orders", in: session)
        XCTAssertEqual(orders.summary?.insertCount, 2)
        XCTAssertEqual(orders.comparisonFailure, failure)
    }

    func testACompareResultIsNotCarriedOntoAPlanWhoseColumnsChanged() throws {
        let session = try makeSession()
        session.adoptDataPlans([makePlan(table: "orders")])
        var run = makePlan(table: "orders", columns: ["id", "email"], summary: makeSummary(inserts: ["1"]))
        run.comparisonFailure = failure

        session.applyComparedSummaries(from: [run])

        let orders = try plan("public.orders", in: session)
        XCTAssertNil(orders.summary)
        XCTAssertNil(orders.comparisonFailure)
    }

    func testACompareResultIsNotCarriedOntoAPlanWhoseFilterChangedWhileItRan() throws {
        let session = try makeSession()
        session.adoptDataPlans([makePlan(table: "orders")])
        let run = makePlan(table: "orders", summary: makeSummary(inserts: ["1"]))

        session.setSourceFilter("id > 10", for: "public.orders")
        session.applyComparedSummaries(from: [run])

        XCTAssertNil(try plan("public.orders", in: session).summary)
    }

    func testRowExclusionsKeepOnlyTheKeysTheNewSummaryLists() throws {
        let session = try makeSession()
        session.adoptDataPlans([makePlan(table: "orders", excludedRowKeys: ["1", "2", "9"])])
        let run = makePlan(table: "orders", summary: makeSummary(inserts: ["1", "3"], updates: ["2"]))

        session.applyComparedSummaries(from: [run])

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, ["1", "2"])
    }

    /// A capped preview lists only part of the difference, so a key missing from it says nothing
    /// about whether the user still refuses that row.
    func testRowExclusionsSurviveAnAnswerWhoseListWasCapped() throws {
        let session = try makeSession()
        session.adoptDataPlans([makePlan(table: "orders", excludedRowKeys: ["1", "9"])])
        let run = makePlan(table: "orders", summary: makeSummary(inserts: ["1"], truncated: true))

        session.applyComparedSummaries(from: [run])

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, ["1", "9"])
    }

    func testACompareResultForOneTableLeavesAnotherTablesExclusionsAlone() throws {
        let session = try makeSession()
        session.adoptDataPlans([
            makePlan(table: "orders", excludedRowKeys: ["9"]),
            makePlan(table: "users", excludedRowKeys: ["9"])
        ])
        let run = makePlan(table: "orders", summary: makeSummary(inserts: ["1"]))

        session.applyComparedSummaries(from: [run])

        XCTAssertEqual(try plan("public.orders", in: session).excludedRowKeys, [])
        XCTAssertEqual(try plan("public.users", in: session).excludedRowKeys, ["9"])
    }

    // MARK: - Banner

    func testTheBannerStillSaysNothingWasWrittenBeforeAnyWrite() throws {
        let session = try makeSession()

        session.lastAction = .compared(Date(), differences: 3)

        XCTAssertTrue(session.bannerText.contains("Nothing has been written."))
    }

    func testTheBannerStopsSayingNothingWasWrittenOnceAWriteHappened() throws {
        let session = try makeSession()
        session.hasWrittenToTarget = true

        XCTAssertEqual(session.bannerText, "Comparing only. Changes applied earlier stay in the target.")

        session.lastAction = .compared(Date(), differences: 3)
        XCTAssertFalse(session.bannerText.contains("Nothing has been written."))

        session.lastAction = .compared(Date(), differences: 1)
        XCTAssertFalse(session.bannerText.contains("Nothing has been written."))

        session.activity = .comparing
        XCTAssertFalse(session.bannerText.contains("Nothing has been written."))
    }

    // MARK: - Helpers

    private func makeSession(connections list: DataScopeConnectionList? = nil) throws -> CompareSyncSession {
        let profileStorage = try XCTUnwrap(storage)
        let connections = list ?? DataScopeConnectionList([
            connection(id: sourceConnection, name: "prod"),
            connection(id: targetConnection, name: "staging")
        ])
        return CompareSyncSession(
            profileStorage: profileStorage, connectionsProvider: { connections.connections }
        )
    }

    /// Two compared tables, each with an answer, a failure message and one excluded row.
    private func makeComparedSession() throws -> CompareSyncSession {
        let session = try makeSession()
        session.adoptDataPlans([
            makePlan(table: "orders", summary: makeSummary(inserts: ["1", "2"]), excludedRowKeys: ["1"]),
            makePlan(table: "users", summary: makeSummary(inserts: ["1", "2"]), excludedRowKeys: ["1"])
        ])
        for index in session.dataPlans.indices {
            session.dataPlans[index].comparisonFailure = failure
        }
        return session
    }

    private func assertAnswerCleared(
        on changedId: String,
        keptOn untouchedId: String,
        in session: CompareSyncSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let changed = try plan(changedId, in: session)
        XCTAssertNil(changed.summary, file: file, line: line)
        XCTAssertNil(changed.comparisonFailure, file: file, line: line)

        let untouched = try plan(untouchedId, in: session)
        XCTAssertEqual(untouched.summary?.insertCount, 2, file: file, line: line)
        XCTAssertEqual(untouched.comparisonFailure, failure, file: file, line: line)
    }

    private func plan(_ id: String, in session: CompareSyncSession) throws -> DataComparePlan {
        try XCTUnwrap(session.dataPlans.first { $0.id == id })
    }

    private func makePlan(
        table: String,
        columns: [String] = ["id", "email", "updated_at"],
        isEnabled: Bool = true,
        summary: DataDiffSummary? = nil,
        excludedRowKeys: Set<String> = []
    ) -> DataComparePlan {
        DataComparePlan(
            table: table,
            schema: "public",
            columns: columns.map { CompareColumn(name: $0, sourceType: "TEXT", targetType: "TEXT") },
            scope: DataTableScope(keyColumns: ["id"]),
            isEnabled: isEnabled,
            summary: summary,
            excludedRowKeys: excludedRowKeys
        )
    }

    private func makeSummary(
        inserts: [String] = [],
        updates: [String] = [],
        deletes: [String] = [],
        identicalCount: Int = 0,
        truncated: Bool = false
    ) -> DataDiffSummary {
        let entries = inserts.map { entry(.insert, key: $0) }
            + updates.map { entry(.update, key: $0) }
            + deletes.map { entry(.delete, key: $0) }
        return DataDiffSummary(
            insertCount: inserts.count,
            updateCount: updates.count,
            deleteCount: deletes.count,
            identicalCount: identicalCount,
            skippedNullKeyCount: 0,
            entries: entries,
            truncatedEntries: truncated,
            differenceDigest: entries.map(\.keyIdentity).joined(separator: ",")
        )
    }

    private func entry(_ kind: RowDiffKind, key: String) -> RowDiffEntry {
        RowDiffEntry(kind: kind, keyDescription: "id = \(key)", keyIdentity: key, sourceRow: nil, targetRow: nil)
    }

    private func statement() -> SyncStatement {
        SyncStatement(sql: "INSERT INTO orders (id) VALUES (1)", objectName: "orders", summary: "Insert 1 row")
    }

    private func connection(id: UUID, name: String) -> DatabaseConnection {
        DatabaseConnection(id: id, name: name, database: name, type: .postgresql, safeModeLevel: .silent)
    }

    private func endpoint(
        connectionId: UUID,
        database: String,
        level: SafeModeLevel = .silent
    ) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: database, schema: "public"),
            connectionName: database,
            databaseType: .postgresql,
            safeModeLevel: level,
            color: .blue
        )
    }
}
