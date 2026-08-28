//
//  ObjectCopySessionTests.swift
//  TableProTests
//
//  What the sheet refuses, and what it builds when it does not.
//

@testable import TablePro
import TableProPluginKit
import XCTest

@MainActor
final class ObjectCopySessionTests: XCTestCase {
    private let sourceConnectionId = UUID()

    private func connection(_ type: DatabaseType = .mysql) -> DatabaseConnection {
        DatabaseConnection(id: sourceConnectionId, name: "Prod", type: type)
    }

    private func endpoint(
        _ database: String,
        type: DatabaseType = .mysql,
        safeMode: SafeModeLevel = .silent,
        connectionId: UUID? = nil
    ) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(
                connectionId: connectionId ?? sourceConnectionId, database: database, schema: nil
            ),
            connectionName: "Prod",
            databaseType: type,
            safeModeLevel: safeMode,
            color: .blue
        )
    }

    private func session(
        mode: ObjectCopyMode = .copyTo,
        preselected: [ObjectCopySelection] = []
    ) -> ObjectCopySession {
        let session = ObjectCopySession(
            mode: mode,
            source: endpoint("shop"),
            sourceConnection: connection(),
            preselected: preselected
        )
        session.availableObjects = [
            ObjectCopySelection(kind: .table, name: "orders", schema: nil),
            ObjectCopySelection(kind: .table, name: "customers", schema: nil)
        ]
        session.selectedObjectIds = Set(session.availableObjects.map(\.id))
        /// Duplicate holds Continue until the destination's create-database options arrive, which
        /// is what keeps it off an engine that cannot create one. These tests start past that.
        session.createDatabaseFormState = .ready
        return session
    }

    // MARK: - Refusals

    func testCopyingNeedsAtLeastOneObject() {
        let subject = session()
        subject.selectedObjectIds = []

        XCTAssertNotNil(subject.reviewDisabledReason)
        XCTAssertNil(subject.request)
    }

    func testCopyToNeedsATarget() {
        XCTAssertNotNil(session().reviewDisabledReason)
    }

    func testAReadOnlyTargetIsRefusedBeforeAnythingIsRead() {
        let subject = session()
        subject.target = endpoint("shop_copy", safeMode: .readOnly, connectionId: UUID())

        XCTAssertNotNil(subject.reviewDisabledReason)
    }

    func testCopyingIntoTheSourceIsRefused() {
        let subject = session()
        subject.target = endpoint("shop")

        XCTAssertNotNil(subject.reviewDisabledReason)
    }

    func testAValidTargetProducesARequest() {
        let subject = session()
        subject.target = endpoint("shop_copy")

        XCTAssertNil(subject.reviewDisabledReason)
        XCTAssertEqual(subject.request?.objects.count, 2)
        XCTAssertEqual(subject.request?.target.database, "shop_copy")
    }

    /// Neither half crosses engines. The row writer emits `INSERT … VALUES`, which a target of
    /// another engine either cannot parse or reads against a namespace it does not have, so a
    /// data-only copy is refused just as a structural one is.
    func testNeitherHalfCrossesEngines() {
        let subject = session()
        subject.target = endpoint("analytics", type: .postgresql, connectionId: UUID())

        subject.content = .structureAndData
        XCTAssertNotNil(subject.reviewDisabledReason)

        subject.content = .data
        XCTAssertNotNil(subject.reviewDisabledReason)
    }

    // MARK: - Duplicate

    func testDuplicateSuggestsACopyName() {
        XCTAssertEqual(ObjectCopySession.suggestedCopyName(for: "shop"), "shop_copy")
        XCTAssertEqual(ObjectCopySession.suggestedCopyName(for: ""), "")
    }

    func testDuplicateNeedsAName() {
        let subject = session(mode: .duplicateDatabase)
        subject.newDatabaseName = "   "

        XCTAssertNotNil(subject.reviewDisabledReason)
    }

    /// `CREATE DATABASE shop` against the database being read would fail, and a name differing only
    /// in case is the same database on the engines that fold identifiers.
    func testDuplicateRefusesTheSourcesOwnName() {
        let subject = session(mode: .duplicateDatabase)
        subject.newDatabaseName = "SHOP"

        XCTAssertNotNil(subject.reviewDisabledReason)
    }

    func testDuplicateBuildsANewDatabaseDestination() {
        let subject = session(mode: .duplicateDatabase)
        subject.newDatabaseName = "shop_copy"

        guard case .newDatabase(_, let name, _) = subject.request?.destination else {
            return XCTFail("Duplicate must create a database")
        }
        XCTAssertEqual(name, "shop_copy")
        XCTAssertTrue(subject.request?.destination.createsDatabase ?? false)
        XCTAssertEqual(subject.request?.target.database, "shop_copy")
    }

    // MARK: - Selection

    func testSearchNarrowsTheListWithoutChangingTheSelection() {
        let subject = session()
        subject.searchText = "ord"

        XCTAssertEqual(subject.filteredObjects.map(\.name), ["orders"])
        XCTAssertEqual(subject.selectedObjects.count, 2)
    }

    // MARK: - Create-database options

    /// MySQL's `createDatabase` needs a character set, so starting before the form answered sent a
    /// request with no values that was guaranteed to be refused.
    func testDuplicateWaitsForTheCreateDatabaseOptions() {
        let subject = session(mode: .duplicateDatabase)
        subject.newDatabaseName = "shop_copy"
        subject.createDatabaseFormState = .loading

        XCTAssertNotNil(subject.reviewDisabledReason)
    }

    /// A driver with no create-database form is one that cannot create a database, which is how
    /// Duplicate stays off DuckDB, Trino and Teradata after the menu has optimistically shown it.
    func testDuplicateRefusesAnEngineThatCannotCreateDatabases() {
        let subject = session(mode: .duplicateDatabase)
        subject.newDatabaseName = "shop_copy"
        subject.createDatabaseFormState = .unsupported

        XCTAssertNotNil(subject.reviewDisabledReason)
    }

    func testDuplicateSurfacesAFailedOptionsRead() {
        let subject = session(mode: .duplicateDatabase)
        subject.newDatabaseName = "shop_copy"
        subject.createDatabaseFormState = .failed("Connection refused")

        XCTAssertEqual(subject.reviewDisabledReason, "Connection refused")
    }

    /// None clears only what is on screen, so a filtered list cannot silently drop the objects the
    /// filter is hiding.
    func testNoneOnlyClearsTheFilteredObjects() {
        let subject = session()
        subject.searchText = "ord"
        subject.selectNone()

        XCTAssertEqual(subject.selectedObjects.map(\.name), ["customers"])
    }

    /// The preselection is what the user right-clicked. Matching it on the name alone selected a
    /// function and a trigger that happened to share the table's name, and matching nothing at all
    /// selected the whole database: with Replace that acted on objects nobody chose.
    func testPreselectionTakesOnlyTheClickedKindAndName() {
        let subject = session(preselected: [
            ObjectCopySelection(kind: .table, name: "orders", schema: nil)
        ])
        subject.availableObjects = [
            ObjectCopySelection(kind: .table, name: "orders", schema: nil),
            ObjectCopySelection(kind: .trigger, name: "orders", schema: nil, owner: "orders"),
            ObjectCopySelection(kind: .table, name: "customers", schema: nil)
        ]
        subject.applyPreselectionForTesting()

        XCTAssertEqual(subject.selectedObjects.map(\.kind), [.table])
        XCTAssertEqual(subject.selectedObjects.map(\.name), ["orders"])
    }

    func testAPreselectionThatMatchesNothingSelectsNothing() {
        let subject = session(preselected: [
            ObjectCopySelection(kind: .table, name: "gone", schema: nil)
        ])
        subject.availableObjects = [
            ObjectCopySelection(kind: .table, name: "orders", schema: nil),
            ObjectCopySelection(kind: .table, name: "customers", schema: nil)
        ]
        subject.applyPreselectionForTesting()

        XCTAssertTrue(
            subject.selectedObjectIds.isEmpty,
            "an unmatched request must never fall back to the whole database"
        )
    }

    /// A right-click on a database carries no preselection, and that is what "copy this database"
    /// means.
    func testNoPreselectionSelectsEverything() {
        let subject = session(preselected: [])
        subject.applyPreselectionForTesting()

        XCTAssertEqual(subject.selectedObjectIds.count, subject.availableObjects.count)
    }

    func testTogglingFlipsOneObject() {
        let subject = session()
        guard let first = subject.availableObjects.first else { return XCTFail("no objects") }

        subject.toggle(first)
        XCTAssertFalse(subject.selectedObjectIds.contains(first.id))

        subject.toggle(first)
        XCTAssertTrue(subject.selectedObjectIds.contains(first.id))
    }

    // MARK: - Content

    func testDataOnlyLeavesStructureOut() {
        XCTAssertFalse(ObjectCopyContent.data.includesStructure)
        XCTAssertTrue(ObjectCopyContent.data.includesData)
        XCTAssertTrue(ObjectCopyContent.structure.includesStructure)
        XCTAssertFalse(ObjectCopyContent.structure.includesData)
        XCTAssertTrue(ObjectCopyContent.structureAndData.includesStructure)
        XCTAssertTrue(ObjectCopyContent.structureAndData.includesData)
    }

    func testOnlyReplaceDropsTheTargetsObject() {
        XCTAssertTrue(ObjectCopyExistingPolicy.replace.dropsTargetObject)
        XCTAssertFalse(ObjectCopyExistingPolicy.skip.dropsTargetObject)
        XCTAssertFalse(ObjectCopyExistingPolicy.appendData.dropsTargetObject)
    }

    func testTablesAndSourceDefinedObjectsAreSeparated() {
        let request = ObjectCopyRequest(
            source: endpoint("shop"),
            destination: .existing(endpoint("shop_copy")),
            objects: [
                ObjectCopySelection(kind: .table, name: "orders", schema: nil),
                ObjectCopySelection(kind: .view, name: "active", schema: nil),
                ObjectCopySelection(kind: .trigger, name: "audit", schema: nil)
            ],
            content: .structureAndData,
            existingPolicy: .skip
        )

        XCTAssertEqual(request.tables.map(\.name), ["orders"])
        XCTAssertEqual(request.sourceDefinedObjects.map(\.name), ["active", "audit"])
    }
}
