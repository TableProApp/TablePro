//
//  QueryTabManagerTableListingTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct QueryTabManagerTableListingTests {
    @Test("A listing tab is a read-only grid of its container, never an editor")
    func listingTabIsReadOnly() throws {
        let manager = QueryTabManager()

        let id = manager.addTableListingTab(title: "Tables: sales", databaseName: "shop", schemaName: "sales")

        let tab = try #require(manager.tabs.first)
        #expect(manager.tabs.count == 1)
        #expect(tab.id == id)
        #expect(manager.selectedTabId == id)
        #expect(tab.tabType == .tableListing)
        #expect(tab.title == "Tables: sales")
        #expect(tab.tableContext.databaseName == "shop")
        #expect(tab.tableContext.schemaName == "sales")
        #expect(tab.tableContext.isEditable == false)
        #expect(tab.content.query.isEmpty)
    }

    @Test("Asking again for the same container returns to its tab")
    func sameContainerReusesTheTab() {
        let manager = QueryTabManager()
        let first = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "sales")
        manager.addTab(initialQuery: "SELECT 1", databaseName: "shop")

        let second = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "sales")

        #expect(second == first)
        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTabId == first)
    }

    @Test("Another schema or database gets a listing of its own")
    func otherContainersGetTheirOwnTab() {
        let manager = QueryTabManager()
        let sales = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "sales")
        let hr = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "hr")
        let other = manager.addTableListingTab(title: "Tables", databaseName: "archive", schemaName: "sales")
        let unscoped = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "")

        #expect(Set([sales, hr, other, unscoped]).count == 4)
        #expect(manager.tabs.first { $0.id == unscoped }?.tableContext.schemaName == nil)
    }

    @Test("The title names the schema only where tables are listed per schema")
    func titleNamesTheSchema() {
        #expect(QueryTabManager.tableListingTitle(kindTitle: "Tables", schemaName: "public") == "Tables: public")
        #expect(QueryTabManager.tableListingTitle(kindTitle: "Collections", schemaName: nil) == "Collections")
        #expect(QueryTabManager.tableListingTitle(kindTitle: "Tables", schemaName: "") == "Tables")
    }

    @Test("A new kind retargets the container's tab and relabels it, never opening another")
    func kindRetargetsTheContainersTab() throws {
        let manager = QueryTabManager()
        let first = manager.addTableListingTab(title: "Tables: sales", databaseName: "shop", schemaName: "sales")
        let version = manager.tabStructureVersion

        let second = manager.addTableListingTab(
            title: "Views: sales", databaseName: "shop", schemaName: "sales", kind: .view
        )

        let tab = try #require(manager.tabs.first)
        #expect(second == first)
        #expect(manager.tabs.count == 1)
        #expect(tab.display.listingKind == .view)
        #expect(tab.title == "Views: sales")
        #expect(manager.tabStructureVersion > version)
        #expect(
            manager.tableListingLanding(databaseName: "shop", schemaName: "sales", kind: .function, isPreview: false)?.tabId
                == first
        )
        #expect(manager.tableListingLanding(databaseName: "shop", schemaName: "", kind: .view, isPreview: false) == nil)
    }

    // MARK: - A kept listing and a preview beside it

    @Test("A preview of another kind opens beside a kept listing and leaves it as it was")
    func previewOpensBesideTheKeptListing() throws {
        let manager = QueryTabManager()
        let kept = manager.addTableListingTab(title: "Tables: sales", databaseName: "shop", schemaName: "sales")
        let version = manager.tabStructureVersion

        let preview = manager.addTableListingTab(
            title: "Views: sales", databaseName: "shop", schemaName: "sales", kind: .view, isPreview: true
        )

        let keptTab = try #require(manager.tabs.first { $0.id == kept })
        let previewTab = try #require(manager.tabs.first { $0.id == preview })
        #expect(preview != kept)
        #expect(manager.tabs.map(\.id) == [kept, preview])
        #expect(manager.selectedTabId == preview)
        #expect(keptTab.display.listingKind == nil)
        #expect(keptTab.title == "Tables: sales")
        #expect(!keptTab.isPreview)
        #expect(previewTab.display.listingKind == .view)
        #expect(previewTab.isPreview)
        #expect(manager.tabStructureVersion > version)
    }

    @Test("A preview asking for the kind a kept listing shows selects that listing")
    func previewSelectsTheKeptListingShowingItsKind() throws {
        let manager = QueryTabManager()
        let kept = manager.addTableListingTab(title: "Views", databaseName: "shop", schemaName: nil, kind: .view)
        manager.addTab(initialQuery: "SELECT 1", databaseName: "shop")
        let count = manager.tabs.count

        let landed = manager.addTableListingTab(
            title: "Views", databaseName: "shop", schemaName: nil, kind: .view, isPreview: true
        )

        #expect(landed == kept)
        #expect(manager.tabs.count == count)
        #expect(manager.selectedTabId == kept)
        #expect(manager.tabs.first { $0.id == kept }?.isPreview == false)
    }

    @Test("Another preview kind retargets the preview beside the kept listing, never the kept one")
    func previewRetargetsOnlyThePreview() throws {
        let manager = QueryTabManager()
        let kept = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: nil)
        let preview = manager.addTableListingTab(
            title: "Views", databaseName: "shop", schemaName: nil, kind: .view, isPreview: true
        )

        let landed = manager.addTableListingTab(
            title: "Functions", databaseName: "shop", schemaName: nil, kind: .function, isPreview: true
        )

        #expect(landed == preview)
        #expect(manager.tabs.map(\.id) == [kept, preview])
        #expect(manager.tabs.first { $0.id == kept }?.display.listingKind == nil)
        #expect(manager.tabs.first { $0.id == preview }?.display.listingKind == .function)
        #expect(manager.tabs.first { $0.id == preview }?.title == "Functions")
        #expect(manager.tabs.first { $0.id == preview }?.isPreview == true)
    }

    @Test("A request to keep retargets the kept listing and closes the preview beside it")
    func keepRequestRetargetsTheKeptListingAndClosesThePreview() throws {
        let manager = QueryTabManager()
        let kept = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: nil)
        let preview = manager.addTableListingTab(
            title: "Views", databaseName: "shop", schemaName: nil, kind: .view, isPreview: true
        )
        let landing = try #require(
            manager.tableListingLanding(databaseName: "shop", schemaName: nil, kind: .function, isPreview: false)
        )
        #expect(landing.tabId == kept)
        #expect(landing.closesPreviewId == preview)

        let landed = manager.addTableListingTab(
            title: "Functions", databaseName: "shop", schemaName: nil, kind: .function
        )

        #expect(landed == kept)
        #expect(manager.tabs.map(\.id) == [kept])
        #expect(manager.selectedTabId == kept)
        #expect(manager.selectedTab?.display.listingKind == .function)
        #expect(manager.selectedTab?.title == "Functions")
        #expect(manager.selectedTab?.isPreview == false)
    }

    @Test("Each container keeps its own kept listing and preview")
    func otherContainersKeepTheirOwnPair() throws {
        let manager = QueryTabManager()
        let shop = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: nil)
        let archive = manager.addTableListingTab(title: "Tables", databaseName: "archive", schemaName: nil)
        let shopViews = manager.addTableListingTab(
            title: "Views", databaseName: "shop", schemaName: nil, kind: .view, isPreview: true
        )

        manager.addTableListingTab(title: "Functions", databaseName: "archive", schemaName: nil, kind: .function)

        #expect(manager.tabs.map(\.id) == [shop, archive, shopViews])
        #expect(manager.tabs.first { $0.id == archive }?.display.listingKind == .function)
        #expect(manager.tabs.first { $0.id == shopViews }?.display.listingKind == .view)
    }

    @Test("Tables is stored as no kind, so it reads like a tab saved before kinds existed")
    func tablesIsStoredAsNoKind() throws {
        let manager = QueryTabManager()
        let id = manager.addTableListingTab(title: "Views", databaseName: "shop", schemaName: nil, kind: .view)

        manager.setTableListingKind(.table, title: "Tables", tabId: id)

        let tab = try #require(manager.tabs.first)
        #expect(tab.display.listingKind == nil)
        #expect(tab.title == "Tables")
    }

    @Test("A preview listing stays a preview until a request to keep it")
    func previewIsKeptOnlyWhenAsked() throws {
        let manager = QueryTabManager()
        let id = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: nil, isPreview: true)
        #expect(manager.tabs.first?.isPreview == true)
        // The structure-change check promotes a preview with this set; a listing preview is kept by the user only.
        #expect(manager.tabs.first?.hasUserInteraction == false)

        manager.addTableListingTab(title: "Views", databaseName: "shop", schemaName: nil, kind: .view, isPreview: true)
        #expect(manager.tabs.first?.isPreview == true)

        manager.addTableListingTab(title: "Views", databaseName: "shop", schemaName: nil, kind: .view)
        #expect(manager.tabs.first?.isPreview == false)
        #expect(manager.tabs.map(\.id) == [id])
    }

    @Test("A preview listing takes the strip slot of the preview it replaces")
    func previewTakesThePreviewsSlot() throws {
        let manager = QueryTabManager()
        manager.addTab(initialQuery: "SELECT 1", databaseName: "shop")
        let before = try #require(manager.selectedTabId)
        let preview = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: nil, isPreview: true)
        manager.addTab(initialQuery: "SELECT 2", databaseName: "shop")
        let after = try #require(manager.selectedTabId)
        manager.selectedTabId = preview

        let replacement = manager.addTableListingTab(
            title: "Functions", databaseName: "archive", schemaName: nil, kind: .function,
            isPreview: true, replacing: preview
        )

        #expect(replacement != preview)
        #expect(manager.tabs.map(\.id) == [before, replacement, after])
        #expect(manager.selectedTabId == replacement)
        #expect(manager.selectedTab?.tableContext.databaseName == "archive")
        #expect(manager.selectedTab?.display.listingKind == .function)
        #expect(manager.selectedTab?.isPreview == true)
    }

    @Test("Only a preview is replaced: a kept tab named as the one to replace stays")
    func keptTabIsNeverReplaced() throws {
        let manager = QueryTabManager()
        let kept = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: nil)

        let added = manager.addTableListingTab(
            title: "Tables", databaseName: "archive", schemaName: nil, isPreview: true, replacing: kept
        )

        #expect(manager.tabs.map(\.id) == [kept, added])
    }

    @Test("A listing a table click takes over forgets its kind")
    func tableRetargetForgetsTheKind() throws {
        let manager = QueryTabManager()
        manager.addTableListingTab(title: "Views", databaseName: "shop", schemaName: nil, kind: .view, isPreview: true)

        try manager.replaceTabContent(tableName: "orders", databaseType: .mysql, databaseName: "shop", isPreview: true)

        #expect(manager.selectedTab?.tabType == .table)
        #expect(manager.selectedTab?.display.listingKind == nil)
    }
}
