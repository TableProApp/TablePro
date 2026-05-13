//
//  EditorTabPayloadTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("EditorTabPayload")
struct EditorTabPayloadTests {

    @Test("Each init creates unique ID")
    func eachInitCreatesUniqueId() {
        let connectionId = UUID()
        let first = EditorTabPayload(connectionId: connectionId)
        let second = EditorTabPayload(connectionId: connectionId)
        #expect(first.id != second.id)
    }

    @Test("connectionId is preserved")
    func connectionIdIsPreserved() {
        let connectionId = UUID()
        let payload = EditorTabPayload(connectionId: connectionId)
        #expect(payload.connectionId == connectionId)
    }

    @Test("Default values are applied")
    func defaultValues() {
        let connectionId = UUID()
        let payload = EditorTabPayload(connectionId: connectionId)
        #expect(payload.tabType == .query)
        #expect(payload.tableName == nil)
        #expect(payload.databaseName == nil)
        #expect(payload.initialQuery == nil)
        #expect(payload.isView == false)
        #expect(payload.showStructure == false)
    }

    @Test("Table payload preserves all fields")
    func tablePayloadPreservesAllFields() {
        let connectionId = UUID()
        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .table,
            tableName: "users",
            databaseName: "mydb",
            isView: true,
            showStructure: true
        )
        #expect(payload.tabType == .table)
        #expect(payload.tableName == "users")
        #expect(payload.databaseName == "mydb")
        #expect(payload.isView == true)
        #expect(payload.showStructure == true)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let id = UUID()
        let connectionId = UUID()
        let payload = EditorTabPayload(
            id: id,
            connectionId: connectionId,
            tabType: .table,
            tableName: "orders",
            databaseName: "shop",
            initialQuery: "SELECT * FROM orders",
            isView: true,
            showStructure: true
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(EditorTabPayload.self, from: data)
        #expect(decoded.id == payload.id)
        #expect(decoded.connectionId == payload.connectionId)
        #expect(decoded.tabType == payload.tabType)
        #expect(decoded.tableName == payload.tableName)
        #expect(decoded.databaseName == payload.databaseName)
        #expect(decoded.initialQuery == payload.initialQuery)
        #expect(decoded.isView == payload.isView)
        #expect(decoded.showStructure == payload.showStructure)
    }

    @Test("Codable with missing optional fields uses defaults")
    func codableWithMissingOptionalFields() throws {
        let id = UUID()
        let connectionId = UUID()
        // Encode TabType.query to get its actual JSON representation
        let tabTypeData = try JSONEncoder().encode(TabType.query)
        let tabTypeJson = String(data: tabTypeData, encoding: .utf8)!
        let json = """
        {
            "id": "\(id.uuidString)",
            "connectionId": "\(connectionId.uuidString)",
            "tabType": \(tabTypeJson)
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorTabPayload.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.connectionId == connectionId)
        #expect(decoded.tabType == .query)
        #expect(decoded.tableName == nil)
        #expect(decoded.databaseName == nil)
        #expect(decoded.initialQuery == nil)
        #expect(decoded.isView == false)
        #expect(decoded.showStructure == false)
    }

    @Test("Different IDs are not equal")
    func differentIdsAreNotEqual() {
        let connectionId = UUID()
        let first = EditorTabPayload(connectionId: connectionId)
        let second = EditorTabPayload(connectionId: connectionId)
        #expect(first != second)
    }

    @Test("Same ID and fields are equal")
    func sameIdAndFieldsAreEqual() {
        let id = UUID()
        let connectionId = UUID()
        let first = EditorTabPayload(id: id, connectionId: connectionId)
        let second = EditorTabPayload(id: id, connectionId: connectionId)
        #expect(first == second)
    }

    @Test("Init from QueryTab maps fields correctly")
    @MainActor
    func initFromQueryTab() throws {
        let tabManager = QueryTabManager()
        try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let tab = tabManager.tabs.first!
        let connectionId = UUID()
        let payload = EditorTabPayload(from: tab, connectionId: connectionId)
        #expect(payload.connectionId == connectionId)
        #expect(payload.tabType == tab.tabType)
        #expect(payload.tableName == tab.tableContext.tableName)
        #expect(payload.databaseName == tab.tableContext.databaseName)
        #expect(payload.initialQuery == tab.content.query)
        #expect(payload.isView == tab.tableContext.isView)
        #expect(payload.showStructure == (tab.display.resultsViewMode == .structure))
    }
}
