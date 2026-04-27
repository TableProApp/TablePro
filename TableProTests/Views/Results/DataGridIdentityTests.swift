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
    private func makeIdentity(
        reloadVersion: Int = 1,
        schemaVersion: Int = 2,
        metadataVersion: Int = 3,
        paginationVersion: Int = 0,
        rowCount: Int = 100,
        columnCount: Int = 5,
        isEditable: Bool = true,
        tabType: TabType? = .table,
        tableName: String? = "users",
        primaryKeyColumns: [String] = ["id"],
        hiddenColumns: Set<String> = []
    ) -> DataGridIdentity {
        var config = DataGridConfiguration()
        config.tabType = tabType
        config.tableName = tableName
        config.primaryKeyColumns = primaryKeyColumns
        config.hiddenColumns = hiddenColumns
        return DataGridIdentity(
            reloadVersion: reloadVersion,
            schemaVersion: schemaVersion,
            metadataVersion: metadataVersion,
            paginationVersion: paginationVersion,
            rowCount: rowCount,
            columnCount: columnCount,
            isEditable: isEditable,
            configuration: config
        )
    }

    @Test("Same values produce equal identities")
    func sameValuesAreEqual() {
        #expect(makeIdentity() == makeIdentity())
    }

    @Test("Different reloadVersion produces unequal identities")
    func differentReloadVersion() {
        #expect(makeIdentity(reloadVersion: 1) != makeIdentity(reloadVersion: 2))
    }

    @Test("Different schemaVersion produces unequal identities")
    func differentSchemaVersion() {
        #expect(makeIdentity(schemaVersion: 2) != makeIdentity(schemaVersion: 3))
    }

    @Test("Different metadataVersion produces unequal identities")
    func differentMetadataVersion() {
        #expect(makeIdentity(metadataVersion: 3) != makeIdentity(metadataVersion: 4))
    }

    @Test("Different paginationVersion produces unequal identities")
    func differentPaginationVersion() {
        #expect(makeIdentity(paginationVersion: 0) != makeIdentity(paginationVersion: 1))
    }

    @Test("Different rowCount produces unequal identities")
    func differentRowCount() {
        #expect(makeIdentity(rowCount: 100) != makeIdentity(rowCount: 200))
    }

    @Test("Different columnCount produces unequal identities")
    func differentColumnCount() {
        #expect(makeIdentity(columnCount: 5) != makeIdentity(columnCount: 10))
    }

    @Test("Different isEditable produces unequal identities")
    func differentIsEditable() {
        #expect(makeIdentity(isEditable: true) != makeIdentity(isEditable: false))
    }

    @Test("Different tabType produces unequal identities")
    func differentTabType() {
        #expect(makeIdentity(tabType: .table) != makeIdentity(tabType: .query))
    }

    @Test("Different tableName produces unequal identities")
    func differentTableName() {
        #expect(makeIdentity(tableName: "users") != makeIdentity(tableName: "orders"))
    }

    @Test("Different primaryKeyColumns produces unequal identities")
    func differentPrimaryKeyColumns() {
        #expect(makeIdentity(primaryKeyColumns: ["id"]) != makeIdentity(primaryKeyColumns: ["uuid"]))
    }

    @Test("Different hiddenColumns produces unequal identities")
    func differentHiddenColumns() {
        #expect(makeIdentity(hiddenColumns: []) != makeIdentity(hiddenColumns: ["name"]))
    }

    @Test("Same hiddenColumns produces equal identities")
    func sameHiddenColumns() {
        #expect(makeIdentity(hiddenColumns: ["name", "email"]) == makeIdentity(hiddenColumns: ["name", "email"]))
    }
}
