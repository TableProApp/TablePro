//
//  TriggerStructTests.swift
//  TableProTests
//
//  Tests for InspectorTrigger and PendingChangeTrigger equality logic.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// MARK: - InspectorTrigger Tests

@Suite("InspectorTrigger")
struct InspectorTriggerTests {
    private func trigger(
        tableName: String? = "users",
        schemaVersion: Int = 1,
        metadataVersion: Int = 0,
        resultsViewMode: ResultsViewMode = .data,
        inspectorRowSourceRevision: Int = 0,
        gridDisplayRevision: Int = 0
    ) -> InspectorTrigger {
        InspectorTrigger(
            tableName: tableName,
            schemaVersion: schemaVersion,
            metadataVersion: metadataVersion,
            resultsViewMode: resultsViewMode,
            inspectorRowSourceRevision: inspectorRowSourceRevision,
            gridDisplayRevision: gridDisplayRevision
        )
    }

    @Test("Same values are equal")
    func sameValuesAreEqual() {
        let a = trigger()
        let b = trigger()
        #expect(a == b)
    }

    @Test("Both nil fields are equal")
    func bothNilFieldsAreEqual() {
        let a = trigger(tableName: nil, schemaVersion: 0)
        let b = trigger(tableName: nil, schemaVersion: 0)
        #expect(a == b)
    }

    @Test("Different tableName produces unequal triggers")
    func differentTableName() {
        #expect(trigger(tableName: "users") != trigger(tableName: "orders"))
    }

    @Test("nil vs non-nil tableName produces unequal triggers")
    func nilVsNonNilTableName() {
        #expect(trigger(tableName: nil) != trigger(tableName: "users"))
    }

    @Test("Different schemaVersion produces unequal triggers")
    func differentSchemaVersion() {
        #expect(trigger(schemaVersion: 1) != trigger(schemaVersion: 2))
    }

    @Test("Different metadataVersion produces unequal triggers")
    func differentMetadataVersion() {
        #expect(trigger(metadataVersion: 0) != trigger(metadataVersion: 1))
    }

    @Test("Switching results view mode produces unequal triggers")
    func differentResultsViewMode() {
        #expect(trigger(resultsViewMode: .data) != trigger(resultsViewMode: .structure))
    }

    @Test("A changed schema row produces unequal triggers")
    func differentRowSourceRevision() {
        #expect(trigger(inspectorRowSourceRevision: 0) != trigger(inspectorRowSourceRevision: 1))
    }

    @Test("A changed grid display produces unequal triggers")
    func differentGridDisplayRevision() {
        #expect(trigger(gridDisplayRevision: 0) != trigger(gridDisplayRevision: 1))
    }
}

// MARK: - PendingChangeTrigger Tests

@Suite("PendingChangeTrigger")
struct PendingChangeTriggerTests {
    private func makeTrigger(
        hasDataChanges: Bool = false,
        pendingTruncates: Set<DatabaseTreeTableRef> = [],
        pendingDeletes: Set<DatabaseTreeTableRef> = [],
        hasStructureChanges: Bool = false,
        isFileDirty: Bool = false,
        hasCreateTablePending: Bool = false
    ) -> PendingChangeTrigger {
        PendingChangeTrigger(
            hasDataChanges: hasDataChanges,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            hasStructureChanges: hasStructureChanges,
            isFileDirty: isFileDirty,
            hasCreateTablePending: hasCreateTablePending
        )
    }

    @Test("Same values are equal")
    func sameValuesAreEqual() {
        let truncate = TestFixtures.makeTableRef(name: "t1")
        let delete = TestFixtures.makeTableRef(name: "t2")
        let a = makeTrigger(hasDataChanges: true, pendingTruncates: [truncate], pendingDeletes: [delete])
        let b = makeTrigger(hasDataChanges: true, pendingTruncates: [truncate], pendingDeletes: [delete])
        #expect(a == b)
    }

    @Test("Empty sets are equal")
    func emptySetsAreEqual() {
        let a = makeTrigger()
        let b = makeTrigger()
        #expect(a == b)
    }

    @Test("Different hasDataChanges produces unequal triggers")
    func differentHasDataChanges() {
        let a = makeTrigger(hasDataChanges: true)
        let b = makeTrigger(hasDataChanges: false)
        #expect(a != b)
    }

    @Test("Different pendingTruncates produces unequal triggers")
    func differentPendingTruncates() {
        let a = makeTrigger(pendingTruncates: [TestFixtures.makeTableRef(name: "t1")])
        let b = makeTrigger(pendingTruncates: [TestFixtures.makeTableRef(name: "t2")])
        #expect(a != b)
    }

    @Test("Different pendingDeletes produces unequal triggers")
    func differentPendingDeletes() {
        let a = makeTrigger(pendingDeletes: [TestFixtures.makeTableRef(name: "d1")])
        let b = makeTrigger(pendingDeletes: [TestFixtures.makeTableRef(name: "d2")])
        #expect(a != b)
    }

    @Test("Different hasStructureChanges produces unequal triggers")
    func differentHasStructureChanges() {
        let a = makeTrigger(hasStructureChanges: true)
        let b = makeTrigger(hasStructureChanges: false)
        #expect(a != b)
    }

    @Test("Different hasCreateTablePending produces unequal triggers")
    func differentHasCreateTablePending() {
        let a = makeTrigger(hasCreateTablePending: true)
        let b = makeTrigger(hasCreateTablePending: false)
        #expect(a != b)
    }
}
