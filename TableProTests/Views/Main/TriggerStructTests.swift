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
    @Test("Same values are equal")
    func sameValuesAreEqual() {
        let a = InspectorTrigger(tableName: "users", schemaVersion: 1, metadataVersion: 0)
        let b = InspectorTrigger(tableName: "users", schemaVersion: 1, metadataVersion: 0)
        #expect(a == b)
    }

    @Test("Both nil fields are equal")
    func bothNilFieldsAreEqual() {
        let a = InspectorTrigger(tableName: nil, schemaVersion: 0, metadataVersion: 0)
        let b = InspectorTrigger(tableName: nil, schemaVersion: 0, metadataVersion: 0)
        #expect(a == b)
    }

    @Test("Different tableName produces unequal triggers")
    func differentTableName() {
        let a = InspectorTrigger(tableName: "users", schemaVersion: 1, metadataVersion: 0)
        let b = InspectorTrigger(tableName: "orders", schemaVersion: 1, metadataVersion: 0)
        #expect(a != b)
    }

    @Test("nil vs non-nil tableName produces unequal triggers")
    func nilVsNonNilTableName() {
        let a = InspectorTrigger(tableName: nil, schemaVersion: 1, metadataVersion: 0)
        let b = InspectorTrigger(tableName: "users", schemaVersion: 1, metadataVersion: 0)
        #expect(a != b)
    }

    @Test("Different schemaVersion produces unequal triggers")
    func differentSchemaVersion() {
        let a = InspectorTrigger(tableName: "users", schemaVersion: 1, metadataVersion: 0)
        let b = InspectorTrigger(tableName: "users", schemaVersion: 2, metadataVersion: 0)
        #expect(a != b)
    }

    @Test("Different metadataVersion produces unequal triggers")
    func differentMetadataVersion() {
        let a = InspectorTrigger(tableName: "users", schemaVersion: 1, metadataVersion: 0)
        let b = InspectorTrigger(tableName: "users", schemaVersion: 1, metadataVersion: 1)
        #expect(a != b)
    }
}

// MARK: - PendingChangeTrigger Tests

@Suite("PendingChangeTrigger")
struct PendingChangeTriggerTests {
    private func makeTrigger(
        hasDataChanges: Bool = false,
        pendingTruncates: Set<String> = [],
        pendingDeletes: Set<String> = [],
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
        let a = makeTrigger(hasDataChanges: true, pendingTruncates: ["t1"], pendingDeletes: ["t2"])
        let b = makeTrigger(hasDataChanges: true, pendingTruncates: ["t1"], pendingDeletes: ["t2"])
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
        let a = makeTrigger(pendingTruncates: ["t1"])
        let b = makeTrigger(pendingTruncates: ["t2"])
        #expect(a != b)
    }

    @Test("Different pendingDeletes produces unequal triggers")
    func differentPendingDeletes() {
        let a = makeTrigger(pendingDeletes: ["d1"])
        let b = makeTrigger(pendingDeletes: ["d2"])
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
