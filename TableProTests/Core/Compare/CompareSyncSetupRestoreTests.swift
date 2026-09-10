//
//  CompareSyncSetupRestoreTests.swift
//  TableProTests
//
//  What a saved comparison restores, and what the window comes back to.
//
//  A saved comparison used to restore the mode and the options and leave both
//  pickers alone, while the list of them was filtered by the pair already on
//  screen. So the one feature meant to save the setup work could only be reached
//  by doing the setup work first.
//

@testable import TablePro
import XCTest

@MainActor
final class CompareSyncSetupRestoreTests: XCTestCase {
    private let sourceConnection = UUID()
    private let targetConnection = UUID()
    private var storage: CompareSyncProfileStorage!
    private var defaults: UserDefaults!
    private let suiteName = "CompareSyncSetupRestoreTests"

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

    private func profile(
        name: String = "Nightly",
        source: UUID? = nil,
        target: UUID? = nil,
        mode: CompareSyncMode = .structure
    ) -> CompareSyncProfile {
        var structureOptions = StructureCompareOptions.default
        structureOptions.ignoreIdentifierCase = false
        return CompareSyncProfile(
            name: name,
            source: DatabaseScope(connectionId: source ?? sourceConnection, database: "prod", schema: "public"),
            target: DatabaseScope(connectionId: target ?? targetConnection, database: "staging", schema: "public"),
            mode: mode,
            includedKinds: [.table, .view],
            structureOptions: structureOptions,
            dataOptions: .default,
            selectedObjects: ["public\u{1F}orders"]
        )
    }

    // MARK: - Storage

    func testTheLastSetupComesBackAsItWentIn() {
        storage.rememberSetup(profile(name: ""))

        let restored = storage.lastSetup()

        XCTAssertEqual(restored?.source.database, "prod")
        XCTAssertEqual(restored?.target.database, "staging")
        XCTAssertEqual(restored?.includedKinds, [.table, .view])
        XCTAssertEqual(restored?.structureOptions.ignoreIdentifierCase, false)
    }

    func testThereIsNoLastSetupBeforeOneIsWritten() {
        XCTAssertNil(storage.lastSetup())
    }

    /// The last setup and the saved comparisons are separate slots: remembering where the window
    /// was must not add an unnamed entry to the list the user curates.
    func testRememberingTheLastSetupDoesNotSaveAComparison() {
        storage.rememberSetup(profile(name: ""))

        XCTAssertTrue(storage.allProfiles().isEmpty)
    }

    // MARK: - Restoring into a session

    func testRestoringWithNoPinnedSourceAdoptsBothScopes() {
        let session = makeSession()

        session.restore(profile(), keepingSource: nil)

        XCTAssertEqual(session.includedKinds, [.table, .view])
        XCTAssertFalse(session.structureOptions.ignoreIdentifierCase)
    }

    /// The window was opened against one connection, so that connection is the source. Inheriting a
    /// target remembered against a different source would arm a database the user never paired with
    /// this one, and the target is the side that gets written to.
    func testAPinnedSourceFromAnotherConnectionDoesNotInheritTheRememberedTarget() {
        let session = makeSession()
        let pinned = endpoint(connectionId: UUID(), database: "other")

        session.restore(profile(), keepingSource: pinned)

        XCTAssertEqual(session.source, pinned)
        XCTAssertNil(session.target, "a target is never inherited across an unrelated source")
    }

    func testAPinnedSourceMatchingTheRememberedOneKeepsItsTarget() {
        let session = makeSession()
        let pinned = endpoint(connectionId: sourceConnection, database: "prod")

        session.restore(profile(), keepingSource: pinned)

        XCTAssertEqual(session.source, pinned)
        XCTAssertEqual(session.target?.connectionId, targetConnection)
    }

    func testRestoringNeverCarriesAnIncludedObjectForward() {
        let session = makeSession()

        session.restore(profile(), keepingSource: nil)

        XCTAssertTrue(session.pendingSelection.isEmpty, "what to change is a decision about one report")
    }

    // MARK: - The saved list

    func testEverySavedComparisonIsOfferedWhateverPairIsOnScreen() {
        let session = makeSession()
        storage.save(profile(name: "Nightly"))

        XCTAssertNil(session.source)
        XCTAssertNil(session.target)
        XCTAssertEqual(
            session.savedProfiles.map(\.name), ["Nightly"],
            "a saved comparison is what picks the pair, so it cannot require the pair first"
        )
    }

    func testLoadingASavedComparisonSetsBothEndpoints() {
        let session = makeSession()

        session.apply(profile())

        XCTAssertEqual(session.source?.connectionId, sourceConnection)
        XCTAssertEqual(session.source?.database, "prod")
        XCTAssertEqual(session.target?.connectionId, targetConnection)
        XCTAssertEqual(session.target?.database, "staging")
        XCTAssertNil(session.setupErrorMessage)
    }

    func testLoadingASavedComparisonWhoseConnectionIsGoneSaysSo() {
        let session = makeSession()

        session.apply(profile(name: "Nightly", target: UUID()))

        XCTAssertNil(session.target, "a target that cannot be resolved is not silently left behind")
        XCTAssertEqual(session.setupErrorMessage, "Nightly names a connection that no longer exists.")
    }

    func testChangingTheSetupWritesItDownForNextTime() {
        let session = makeSession()
        session.source = endpoint(connectionId: sourceConnection, database: "prod")
        session.target = endpoint(connectionId: targetConnection, database: "staging")

        session.resetComparison()

        XCTAssertEqual(storage.lastSetup()?.source.database, "prod")
        XCTAssertEqual(storage.lastSetup()?.target.database, "staging")
    }

    func testAHalfChosenPairIsNotWrittenDown() {
        let session = makeSession()
        session.source = endpoint(connectionId: sourceConnection, database: "prod")

        session.resetComparison()

        XCTAssertNil(storage.lastSetup(), "one endpoint is not a comparison to come back to")
    }

    /// One connection reaches many databases, so a connection match is not a pair. The remembered
    /// target is the side that gets written to, and inheriting it across databases would arm a
    /// database the user never paired with this one.
    func testAPinnedSourceOnTheSameConnectionButAnotherDatabaseInheritsNoTarget() {
        let session = makeSession()
        let pinned = endpoint(connectionId: sourceConnection, database: "other")

        session.restore(profile(), keepingSource: pinned)

        XCTAssertEqual(session.source, pinned)
        XCTAssertNil(session.target, "a connection is not a pair")
    }

    // MARK: - Fencing

    func testEverySetupChangeMovesTheGeneration() {
        let session = makeSession()
        let first = session.setupGeneration

        session.resetComparison()

        XCTAssertNotEqual(session.setupGeneration, first)
        XCTAssertFalse(session.isCurrent(first), "an answer built for the old setup is no longer current")
        XCTAssertTrue(session.isCurrent(session.setupGeneration))
    }

    func testLoadingAProfileIsRefusedWhileWorkIsRunning() {
        let session = makeSession()
        session.activity = .applying

        XCTAssertFalse(session.canLoadProfile)
        XCTAssertFalse(session.apply(profile()), "a run in flight owns the target it captured")
        XCTAssertNil(session.source, "nothing is adopted from a refused load")
    }

    /// The option changes a load causes fire their own reset, which clears `errorMessage`. A message
    /// about the setup has to outlive that or the failed load reports nothing at all.
    func testAMissingConnectionSurvivesTheResetTheLoadCauses() {
        let session = makeSession()

        session.apply(profile(name: "Nightly", target: UUID()))
        session.resetComparison()

        XCTAssertEqual(session.setupErrorMessage, "Nightly names a connection that no longer exists.")
    }

    func testChoosingBothEndpointsClearsTheSetupError() {
        let session = makeSession()
        session.apply(profile(name: "Nightly", target: UUID()))

        session.target = endpoint(connectionId: targetConnection, database: "staging")
        session.clearSetupErrorIfResolved()

        XCTAssertNil(session.setupErrorMessage)
    }

    // MARK: - Data plans

    /// A saved comparison names its tables, and the list now arrives before Compare. Left pending,
    /// the saved set was reapplied at the next Compare over whatever the user had ticked since.
    func testAdoptingPlansConsumesTheSavedSelection() {
        let session = makeSession()
        session.pendingSelection = ["public.orders"]

        session.adoptDataPlans([plan(id: "public.orders"), plan(id: "public.customers")])

        XCTAssertEqual(session.dataPlans.filter(\.isEnabled).map(\.id), ["public.orders"])
        XCTAssertTrue(session.pendingSelection.isEmpty)
        XCTAssertTrue(session.hasLoadedDataPlans)
    }

    func testAdoptingPlansWithNothingPendingLeavesThemUnticked() {
        let session = makeSession()

        session.adoptDataPlans([plan(id: "public.orders")])

        XCTAssertTrue(session.dataPlans.allSatisfy { !$0.isEnabled })
    }

    private func plan(id: String) -> DataComparePlan {
        DataComparePlan(
            table: String(id.split(separator: ".").last ?? ""),
            schema: "public",
            targetSchema: "public",
            columns: ["id"],
            columnDescriptors: [KeyColumnDescriptor(name: "id", dataType: "INTEGER", collation: nil)],
            generatedColumns: [],
            keyColumns: ["id"],
            isEnabled: false,
            excludedRowKeys: []
        )
    }

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

    private func endpoint(connectionId: UUID, database: String) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: database, schema: "public"),
            connectionName: database,
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
    }
}
