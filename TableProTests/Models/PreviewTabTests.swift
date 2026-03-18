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

    @Test("TabSettings enablePreviewTabs defaults to true")
    func tabSettingsDefaultsToTrue() {
        let settings = TabSettings.default
        #expect(settings.enablePreviewTabs == true)
    }

    @Test("Preview table tab can be added via addPreviewTableTab")
    @MainActor
    func addPreviewTableTab() {
        let manager = QueryTabManager()
        manager.addPreviewTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTab?.isPreview == true)
        #expect(manager.selectedTab?.tableName == "users")
    }

    @Test("replaceTabContent can set isPreview flag")
    @MainActor
    func replaceTabContentSetsPreview() {
        let manager = QueryTabManager()
        manager.addPreviewTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let replaced = manager.replaceTabContent(
            tableName: "orders",
            databaseType: .mysql,
            databaseName: "mydb",
            isPreview: true
        )
        #expect(replaced == true)
        #expect(manager.selectedTab?.isPreview == true)
        #expect(manager.selectedTab?.tableName == "orders")
    }

    @Test("replaceTabContent defaults to non-preview")
    @MainActor
    func replaceTabContentDefaultsNonPreview() {
        let manager = QueryTabManager()
        manager.addPreviewTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let replaced = manager.replaceTabContent(
            tableName: "orders",
            databaseType: .mysql,
            databaseName: "mydb"
        )
        #expect(replaced == true)
        #expect(manager.selectedTab?.isPreview == false)
    }

    @Test("TabSettings decodes with missing enablePreviewTabs key (backward compat)")
    func tabSettingsBackwardCompatDecoding() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(TabSettings.self, from: json)
        #expect(decoded.enablePreviewTabs == true)
    }

    @Test("TabSettings decodes with enablePreviewTabs set to false")
    func tabSettingsDecodesExplicitFalse() throws {
        let json = Data(#"{"enablePreviewTabs":false}"#.utf8)
        let decoded = try JSONDecoder().decode(TabSettings.self, from: json)
        #expect(decoded.enablePreviewTabs == false)
    }

    @Test("EditorTabPayload isPreview defaults to false")
    func editorTabPayloadDefaultsFalse() {
        let payload = EditorTabPayload(connectionId: UUID())
        #expect(payload.isPreview == false)
    }

    @Test("EditorTabPayload isPreview can be set to true")
    func editorTabPayloadCanBePreview() {
        let payload = EditorTabPayload(connectionId: UUID(), isPreview: true)
        #expect(payload.isPreview == true)
    }
}
