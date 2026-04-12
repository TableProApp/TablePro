//
//  PreviewTabTests.swift
//  TableProTests
//
//  Tests for preview tab data model behavior
//

import Foundation
@testable import TablePro
import Testing

@Suite("Preview Tab")
struct PreviewTabTests {
    @Test("QueryTab isPreview defaults to false")
    func queryTabIsPreviewDefaultsFalse() {
        let tab = QueryTab(title: "Test", tabType: .query)
        #expect(tab.isPreview == false)
    }

    @Test("QueryTab from persisted tab is not preview")
    func queryTabFromPersistedIsNotPreview() {
        let persisted = PersistedTab(
            id: UUID(),
            title: "users",
            query: "SELECT * FROM users",
            tabType: .table,
            tableName: "users"
        )
        let tab = QueryTab(from: persisted)
        #expect(tab.isPreview == false)
    }

    @Test("replaceTabContent defaults to non-preview")
    @MainActor
    func replaceTabContentDefaultsNonPreview() {
        let manager = QueryTabManager()
        manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let replaced = manager.replaceTabContent(
            tableName: "orders",
            databaseType: .mysql,
            databaseName: "mydb"
        )
        #expect(replaced == true)
        #expect(manager.selectedTab?.isPreview == false)
        #expect(manager.selectedTab?.tableName == "orders")
    }

    @Test("EditorTabPayload isPreview defaults to false")
    func editorTabPayloadDefaultsFalse() {
        let payload = EditorTabPayload(connectionId: UUID())
        #expect(payload.isPreview == false)
    }
}
