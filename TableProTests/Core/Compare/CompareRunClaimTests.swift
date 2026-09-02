//
//  CompareRunClaimTests.swift
//  TableProTests
//
//  What a comparison in flight still owns, and what it has to give up.
//
//  One revision counter used to answer both "are these statements still the
//  user's choices" and "is this answer still the question on screen". A
//  comparison advances the first itself as it publishes, so it could never pass
//  its own fence: the cross-engine warning and every cancellation message were
//  unreachable, and ticking one more table part way through a run threw away
//  every summary the run had already computed.
//

@testable import TablePro
import XCTest

@MainActor
final class CompareRunClaimTests: XCTestCase {
    private let sourceConnection = UUID()
    private let targetConnection = UUID()
    private var storage: CompareSyncProfileStorage!
    private var defaults: UserDefaults!
    private let suiteName = "CompareRunClaimTests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        storage = CompareSyncProfileStorage(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        storage = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - The fence

    func testAComparisonStillOwnsItsAnswerAfterInvalidatingTheScriptItReplaced() {
        let session = makeSession()
        let claim = session.currentClaim

        session.invalidateScript()

        XCTAssertTrue(session.ownsAnswer(claim), "publishing a report is what makes the old script stale")
        XCTAssertFalse(session.owns(claim), "the statements it replaced are not the ones it may publish")
    }

    func testTickingATableLeavesARunningComparisonItsAnswer() {
        let session = makeSession()
        session.adoptDataPlans([plan(table: "orders"), plan(table: "users")])
        let claim = session.currentClaim

        session.setPlanEnabled(true, for: "orders")

        XCTAssertTrue(session.ownsAnswer(claim), "which tables to apply is not which question was asked")
    }

    func testChangingAKeyColumnTakesTheAnswerFromARunningComparison() {
        let session = makeSession()
        session.adoptDataPlans([plan(table: "orders")])
        let claim = session.currentClaim

        session.setKeyColumns(["email"], for: "orders")

        XCTAssertFalse(session.ownsAnswer(claim), "a new key is a different question")
    }

    func testUnpickingAComparedColumnTakesTheAnswerFromARunningComparison() {
        let session = makeSession()
        let claim = session.currentClaim

        session.clearDataSummaries()

        XCTAssertFalse(session.ownsAnswer(claim))
    }

    func testChangingTheSetupTakesTheAnswerFromARunningComparison() {
        let session = makeSession()
        let claim = session.currentClaim

        session.resetComparison()

        XCTAssertFalse(session.ownsAnswer(claim))
    }

    // MARK: - Summaries

    func testAComparisonCarriesItsSummariesOntoTheTicksMadeWhileItRan() {
        let session = makeSession()
        session.adoptDataPlans([plan(table: "orders"), plan(table: "users")])
        var compared = plan(table: "orders")
        compared.summary = summary(insertCount: 3)

        session.setPlanEnabled(true, for: "users")
        session.applyComparedSummaries(from: [compared])

        XCTAssertEqual(session.dataPlans.first { $0.id == "orders" }?.summary?.insertCount, 3)
        XCTAssertEqual(
            session.dataPlans.first { $0.id == "users" }?.isEnabled, true,
            "a tick made during the run is the user's, not the run's to overwrite"
        )
    }

    func testASummaryIsNotCarriedOntoAPlanWhoseKeyChangedUnderIt() {
        let session = makeSession()
        session.adoptDataPlans([plan(table: "orders", keyColumns: ["id"])])
        var compared = plan(table: "orders", keyColumns: ["id"])
        compared.summary = summary(insertCount: 3)

        session.setKeyColumns(["email"], for: "orders")
        session.applyComparedSummaries(from: [compared])

        XCTAssertNil(
            session.dataPlans.first?.summary,
            "the run answered for a key the plan no longer uses"
        )
    }

    func testASummaryIsNotCarriedOntoATableTheRebuiltListNoLongerHolds() {
        let session = makeSession()
        session.adoptDataPlans([plan(table: "orders")])
        var compared = plan(table: "dropped")
        compared.summary = summary(insertCount: 1)

        session.applyComparedSummaries(from: [compared])

        XCTAssertEqual(session.dataPlans.map(\.id), ["orders"])
        XCTAssertNil(session.dataPlans.first?.summary)
    }

    // MARK: - What a cancel may not take with it

    /// Apply cancels the work in flight and then reads the statements it is about to run, so a
    /// cancel that discarded the script left every confirmed Apply executing nothing against the
    /// target and reporting that it had succeeded.
    func testCancellingRunningWorkLeavesTheScriptItIsAboutToApply() {
        let session = makeSession()
        session.statements = [
            SyncStatement(sql: "DROP TABLE orders", objectName: "orders", summary: "Drop orders")
        ]

        session.cancelRunningWork()

        XCTAssertEqual(session.statements.count, 1)
    }

    func testCancellingRunningWorkStillTakesOwnershipFromTheRunItStopped() {
        let session = makeSession()
        let claim = session.currentClaim

        session.cancelRunningWork()

        XCTAssertFalse(session.ownsAnswer(claim))
        XCTAssertFalse(session.owns(claim))
    }

    // MARK: - Structure inclusions

    func testARecompareKeepsWhatTheUserIncludedWhileItRan() {
        let session = makeSession()
        let report = CompareReport(results: [result(name: "orders"), result(name: "users")])
        session.report = report
        session.setIncluded(true, for: result(name: "orders"))

        session.adoptActions(for: report)

        XCTAssertNotEqual(session.action(for: result(name: "orders")), .skip)
    }

    func testARecompareDropsAnInclusionForAnObjectItNoLongerFinds() {
        let session = makeSession()
        session.report = CompareReport(results: [result(name: "dropped")])
        session.setIncluded(true, for: result(name: "dropped"))

        session.adoptActions(for: CompareReport(results: [result(name: "orders")]))

        XCTAssertEqual(session.actions.count, 0)
    }

    // MARK: - Stopping

    func testStoppingAComparisonSaysSoWithoutWaitingForTheTaskToNotice() {
        let session = makeSession()
        session.activity = .comparing

        session.stopRunningWork()

        XCTAssertEqual(session.informationalMessage, "Comparison cancelled.")
    }

    func testStoppingAScriptBuildNamesTheScript() {
        let session = makeSession()
        session.activity = .buildingScript

        session.stopRunningWork()

        XCTAssertEqual(session.informationalMessage, "Script generation cancelled.")
    }

    /// A sync writes as it goes, so stopping one is not the same as stopping a read: the statements
    /// that already ran stay applied, and the message has to say so.
    func testStoppingASyncSaysWhatStaysApplied() {
        let session = makeSession()
        session.activity = .applying

        session.stopRunningWork()

        XCTAssertEqual(session.informationalMessage, "Sync stopped. Statements that already ran stay applied.")
    }

    func testStoppingWithNothingRunningSaysNothing() {
        let session = makeSession()

        session.stopRunningWork()

        XCTAssertNil(session.informationalMessage)
    }

    func testResettingTheSetupCancelsTheWorkTheOldSetupStarted() {
        let session = makeSession()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        session.runTask = task

        session.resetComparison()

        XCTAssertTrue(task.isCancelled, "a preload taking the slot would leave Stop nothing to cancel")
    }

    // MARK: - Helpers

    private func makeSession() -> CompareSyncSession {
        let connections = [
            connection(id: sourceConnection, name: "prod"),
            connection(id: targetConnection, name: "staging")
        ]
        return CompareSyncSession(profileStorage: storage, connectionsProvider: { connections })
    }

    private func connection(id: UUID, name: String) -> DatabaseConnection {
        DatabaseConnection(id: id, name: name, database: name, type: .postgresql)
    }

    private func plan(table: String, keyColumns: [String] = ["id"]) -> DataComparePlan {
        DataComparePlan(
            table: table,
            schema: nil,
            columns: ["id", "email"],
            keyColumns: keyColumns,
            isEnabled: false
        )
    }

    private func result(name: String) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .table, schema: nil, name: name),
            status: .onlyInSource
        )
    }

    private func summary(insertCount: Int) -> DataDiffSummary {
        DataDiffSummary(
            insertCount: insertCount,
            updateCount: 0,
            deleteCount: 0,
            identicalCount: 0,
            skippedNullKeyCount: 0,
            entries: [],
            truncatedEntries: false
        )
    }
}
