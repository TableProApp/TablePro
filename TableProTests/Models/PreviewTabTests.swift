//
//  PreviewTabTests.swift
//  TableProTests
//
//  Tests for preview tab data model behavior
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

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
        let tab = QueryTab(from: persisted, defaultPageSize: 1_000)
        #expect(tab.isPreview == false)
    }

    @Test("TabSettings enablePreviewTabs defaults to true")
    func tabSettingsDefaultsToTrue() {
        let settings = TabSettings.default
        #expect(settings.enablePreviewTabs == true)
    }

    @Test("A table tab added with isPreview is a preview tab")
    @MainActor
    func addPreviewTab() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb", isPreview: true)
        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTab?.isPreview == true)
        #expect(manager.selectedTab?.tableContext.tableName == "users")
    }

    @Test("replaceTabContent can set isPreview flag")
    @MainActor
    func replaceTabContentSetsPreview() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb", isPreview: true)
        let replaced = try manager.replaceTabContent(
            tableName: "orders",
            databaseType: .mysql,
            databaseName: "mydb",
            isPreview: true
        )
        #expect(replaced == true)
        #expect(manager.selectedTab?.isPreview == true)
        #expect(manager.selectedTab?.tableContext.tableName == "orders")
    }

    @Test("replaceTabContent defaults to non-preview")
    @MainActor
    func replaceTabContentDefaultsNonPreview() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb", isPreview: true)
        let replaced = try manager.replaceTabContent(
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

    // MARK: - Keeping a preview tab (issue #2436)

    @Test("promotePreviewTab keeps a tab that is not the selected one")
    @MainActor
    func promoteKeepsAnUnselectedTab() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb", isPreview: true)
        let previewTabId = try #require(manager.selectedTabId)
        try manager.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "mydb")

        manager.promotePreviewTab(id: previewTabId)

        #expect(manager.tabs.first { $0.id == previewTabId }?.isPreview == false)
        #expect(manager.selectedTabId != previewTabId)
    }

    @Test("promotePreviewTab is a no-op on a tab that is already permanent")
    @MainActor
    func promoteIsANoOpOnAPermanentTab() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let tabId = try #require(manager.selectedTabId)

        manager.promotePreviewTab(id: tabId)

        #expect(manager.tabs.first { $0.id == tabId }?.isPreview == false)
    }

    @Test("promotePreviewTab ignores an id no tab has")
    @MainActor
    func promoteIgnoresAnUnknownId() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb", isPreview: true)

        manager.promotePreviewTab(id: UUID())

        #expect(manager.selectedTab?.isPreview == true)
    }

    /// Keeping a tab is not pinning: the tab holds its place in the strip.
    @Test("promotePreviewTab does not reorder the strip")
    @MainActor
    func promoteDoesNotReorderTheStrip() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb", isPreview: true)
        let previewTabId = try #require(manager.selectedTabId)
        try manager.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "mydb")
        let orderBefore = manager.tabs.map(\.id)

        manager.promotePreviewTab(id: previewTabId)

        #expect(manager.tabs.map(\.id) == orderBefore)
    }

    @Test("canPromotePreviewTab answers for a preview tab, a permanent tab and an unknown id")
    @MainActor
    func canPromoteAnswersEachCase() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb", isPreview: true)
        let previewTabId = try #require(manager.selectedTabId)
        try manager.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "mydb")
        let permanentTabId = try #require(manager.selectedTabId)

        #expect(manager.canPromotePreviewTab(id: previewTabId))
        #expect(manager.canPromotePreviewTab(id: permanentTabId) == false)
        #expect(manager.canPromotePreviewTab(id: UUID()) == false)

        manager.promotePreviewTab(id: previewTabId)
        #expect(manager.canPromotePreviewTab(id: previewTabId) == false)
    }
}
