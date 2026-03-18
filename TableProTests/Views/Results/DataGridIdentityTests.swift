//
//  DataGridIdentityTests.swift
//  TableProTests
//
//  Tests for DataGridIdentity equality used to skip redundant updateNSView calls.
//

import Foundation
@testable import TablePro
import Testing

@Suite("DataGridIdentity")
struct DataGridIdentityTests {
    @Test("Same values produce equal identities")
    func sameValuesAreEqual() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        #expect(a == b)
    }

    @Test("Different reloadVersion produces unequal identities")
    func differentReloadVersion() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 2, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        #expect(a != b)
    }

    @Test("Different resultVersion produces unequal identities")
    func differentResultVersion() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 3, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        #expect(a != b)
    }

    @Test("Different metadataVersion produces unequal identities")
    func differentMetadataVersion() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 4, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        #expect(a != b)
    }

    @Test("Different rowCount produces unequal identities")
    func differentRowCount() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 200, columnCount: 5, isEditable: true, hiddenColumns: [])
        #expect(a != b)
    }

    @Test("Different columnCount produces unequal identities")
    func differentColumnCount() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 10, isEditable: true, hiddenColumns: [])
        #expect(a != b)
    }

    @Test("Different isEditable produces unequal identities")
    func differentIsEditable() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: false, hiddenColumns: [])
        #expect(a != b)
    }

    @Test("Different hiddenColumns produces unequal identities")
    func differentHiddenColumns() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: [])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: ["name"])
        #expect(a != b)
    }

    @Test("Same hiddenColumns produces equal identities")
    func sameHiddenColumns() {
        let a = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: ["name", "email"])
        let b = DataGridIdentity(reloadVersion: 1, resultVersion: 2, metadataVersion: 3, rowCount: 100, columnCount: 5, isEditable: true, hiddenColumns: ["name", "email"])
        #expect(a == b)
    }
}
