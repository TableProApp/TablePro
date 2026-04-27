//
//  TriggerStructTests.swift
//  TableProTests
//
//  Tests for InspectorTrigger and PendingChangeTrigger equality logic.
//

import Foundation
@testable import TablePro
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
    @Test("Same values are equal")
    func sameValuesAreEqual() {
        let a = PendingChangeTrigger(hasDataChanges: true, pendingTruncates: ["t1"], pendingDeletes: ["t2"], hasStructureChanges: false, isFileDirty: false)
        let b = PendingChangeTrigger(hasDataChanges: true, pendingTruncates: ["t1"], pendingDeletes: ["t2"], hasStructureChanges: false, isFileDirty: false)
        #expect(a == b)
    }

    @Test("Empty sets are equal")
    func emptySetsAreEqual() {
        let a = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: [], pendingDeletes: [], hasStructureChanges: false, isFileDirty: false)
        let b = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: [], pendingDeletes: [], hasStructureChanges: false, isFileDirty: false)
        #expect(a == b)
    }

    @Test("Different hasDataChanges produces unequal triggers")
    func differentHasDataChanges() {
        let a = PendingChangeTrigger(hasDataChanges: true, pendingTruncates: [], pendingDeletes: [], hasStructureChanges: false, isFileDirty: false)
        let b = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: [], pendingDeletes: [], hasStructureChanges: false, isFileDirty: false)
        #expect(a != b)
    }

    @Test("Different pendingTruncates produces unequal triggers")
    func differentPendingTruncates() {
        let a = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: ["t1"], pendingDeletes: [], hasStructureChanges: false, isFileDirty: false)
        let b = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: ["t2"], pendingDeletes: [], hasStructureChanges: false, isFileDirty: false)
        #expect(a != b)
    }

    @Test("Different pendingDeletes produces unequal triggers")
    func differentPendingDeletes() {
        let a = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: [], pendingDeletes: ["d1"], hasStructureChanges: false, isFileDirty: false)
        let b = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: [], pendingDeletes: ["d2"], hasStructureChanges: false, isFileDirty: false)
        #expect(a != b)
    }

    @Test("Different hasStructureChanges produces unequal triggers")
    func differentHasStructureChanges() {
        let a = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: [], pendingDeletes: [], hasStructureChanges: true, isFileDirty: false)
        let b = PendingChangeTrigger(hasDataChanges: false, pendingTruncates: [], pendingDeletes: [], hasStructureChanges: false, isFileDirty: false)
        #expect(a != b)
    }
}
