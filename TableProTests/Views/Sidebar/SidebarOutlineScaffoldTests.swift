//
//  SidebarOutlineScaffoldTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProSyncTransport
import Testing

@testable import TablePro

/// The two sidebar lists are configured from one place now. They had drifted apart on exactly the
/// settings nobody looks at twice, so these assert the settings rather than the drift.
@Suite("Sidebar outline scaffold")
@MainActor
struct SidebarOutlineScaffoldTests {
    private func makeScrollView(
        multipleSelection: Bool = true,
        rowSize: SidebarRowSizePreference = .matchSystem
    ) -> NSScrollView {
        SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TestColumn",
                allowsMultipleSelection: multipleSelection,
                rowSizePreference: rowSize
            )
        )
    }

    private func outline(_ scrollView: NSScrollView) throws -> NSOutlineView {
        try #require(scrollView.documentView as? NSOutlineView)
    }

    @Test("Both lists get the source list style and no header")
    func configuresAsASourceList() throws {
        let outlineView = try outline(makeScrollView())

        #expect(outlineView.style == .sourceList)
        #expect(outlineView.headerView == nil)
        #expect(outlineView.floatsGroupRows == false)
    }

    /// Expansion is per connection, and while a filter is active it is the search's rather than the
    /// user's. Neither fits AppKit's single global autosave record.
    @Test("Expansion is never autosaved by AppKit")
    func doesNotAutosaveExpansion() throws {
        #expect(try outline(makeScrollView()).autosaveExpandedItems == false)
    }

    @Test("The outline column is created and set as the outline column")
    func createsTheOutlineColumn() throws {
        let outlineView = try outline(makeScrollView())

        #expect(outlineView.tableColumns.count == 1)
        #expect(outlineView.outlineTableColumn === outlineView.tableColumns.first)
    }

    @Test("Multiple selection follows the caller")
    func multipleSelectionIsConfigurable() throws {
        #expect(try outline(makeScrollView(multipleSelection: true)).allowsMultipleSelection)
        #expect(try outline(makeScrollView(multipleSelection: false)).allowsMultipleSelection == false)
    }

    /// The scroller style is the user's "Show scroll bars" setting, so the scaffold must leave it
    /// alone. One of the two lists used to force overlay scrollers.
    @Test("The scroll view leaves the system scroller preference alone")
    func doesNotOverrideScrollerStyle() {
        let scrollView = makeScrollView()

        #expect(scrollView.scrollerStyle == NSScroller.preferredScrollerStyle)
        #expect(scrollView.autohidesScrollers)
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.hasHorizontalScroller == false)
    }

    @Test("The list draws no background of its own, so the sidebar material shows through")
    func drawsNoBackground() throws {
        let scrollView = makeScrollView()

        #expect(scrollView.drawsBackground == false)
        #expect(try outline(scrollView).backgroundColor == .clear)
    }

    @Test("An explicit row size reaches the outline, and Match System defers to AppKit")
    func appliesTheRowSize() throws {
        #expect(try outline(makeScrollView(rowSize: .large)).rowSizeStyle == .large)
        #expect(try outline(makeScrollView(rowSize: .matchSystem)).rowSizeStyle == .default)
    }

    @Test("A row size change is applied to a list already on screen")
    func reappliesRowSizeOnUpdate() throws {
        let scrollView = makeScrollView(rowSize: .small)
        #expect(try outline(scrollView).rowSizeStyle == .small)

        SidebarOutlineScaffold.applyRowSize(.large, to: scrollView)

        #expect(try outline(scrollView).rowSizeStyle == .large)
    }
}

/// Both lists host their rows through one base now. They used to inset by different amounts, so the
/// two tabs of a single sidebar drew rows at different heights.
@Suite("Sidebar hosting cell")
@MainActor
struct SidebarHostingCellViewTests {
    @Test("A row is hosted once and its content swapped on reuse")
    func reusesTheHostingView() {
        let cell = SidebarHostingCellView<Text>()
        cell.update(rootView: Text("first"))
        let hosted = cell.hostedView

        cell.update(rootView: Text("second"))

        #expect(cell.hostedView === hosted)
        #expect(cell.subviews.filter { $0 is NSHostingView<Text> }.count == 1)
    }

    @Test("Both lists inset their content by the same amount")
    func sharesOneInset() {
        #expect(SidebarHostingCellView<Text>.contentInset == FavoritesOutlineCellView<Text>.contentInset)
    }
}

@Suite("Database tree favorite refresh", .serialized)
@MainActor
struct DatabaseTreeFavoriteRefreshTests {
    private static let width: CGFloat = 320
    private static let height: CGFloat = 120

    @Test("Adding and removing a favorite repaints every visible copy without replacing its host")
    func favoriteMutationRepaintsVisibleRows() throws {
        let favoritesSuite = "DatabaseTreeFavoriteRefreshTests.favorites.\(UUID().uuidString)"
        let syncSuite = "DatabaseTreeFavoriteRefreshTests.sync.\(UUID().uuidString)"
        let favoritesDefaults = try #require(UserDefaults(suiteName: favoritesSuite))
        let syncDefaults = try #require(UserDefaults(suiteName: syncSuite))
        favoritesDefaults.removePersistentDomain(forName: favoritesSuite)
        syncDefaults.removePersistentDomain(forName: syncSuite)
        defer {
            favoritesDefaults.removePersistentDomain(forName: favoritesSuite)
            syncDefaults.removePersistentDomain(forName: syncSuite)
        }

        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let storage = FavoriteTablesStorage(userDefaults: favoritesDefaults, syncTracker: tracker)
        let coordinator = DatabaseTreeOutlineCoordinator(favoriteTablesStorage: storage)
        let connectionId = UUID()
        let table = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        let ref = DatabaseTreeTableRef(database: "shop", schema: "public", table: table)
        let ordinary = DatabaseTreeNode(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
        let recent = DatabaseTreeNode(id: DatabaseTreeNode.recentTableId(ref), kind: .recentTable(ref))
        let outlineView = NSOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "FavoriteRefreshColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView

        coordinator.connectionId = connectionId
        coordinator.databaseType = .sqlite
        coordinator.childrenCache[""] = [ordinary, recent]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()
        settle(window)

        #expect(outlineView.numberOfRows == 2)
        let cells = try (0..<2).map { row in
            try #require(
                outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? DatabaseTreeCellView
            )
        }
        settle(window)
        let hosts = cells.map(\.hostedView)
        let unfavoritePixels = try cells.map(trailingPixels)

        coordinator.toggleFavorite(ref)
        settle(window)

        #expect(coordinator.isFavorite(ref))
        #expect(cells.indices.allSatisfy { cells[$0].hostedView === hosts[$0] })
        let favoritePixels = try cells.map(trailingPixels)
        #expect(zip(unfavoritePixels, favoritePixels).allSatisfy(!=))

        coordinator.toggleFavorite(ref)
        settle(window)

        #expect(!coordinator.isFavorite(ref))
        #expect(cells.indices.allSatisfy { cells[$0].hostedView === hosts[$0] })
        let removedPixels = try cells.map(trailingPixels)
        #expect(zip(favoritePixels, removedPixels).allSatisfy(!=))
    }

    private func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.layoutIfNeeded()
    }

    private func trailingPixels(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let bitmap = try #require(representation.bitmapData)
        let bytesPerPixel = try #require(representation.bitsPerPixel / 8 > 0 ? representation.bitsPerPixel / 8 : nil)
        let scale = CGFloat(representation.pixelsWide) / view.bounds.width
        let trailingWidth = min(representation.pixelsWide, Int((32 * scale).rounded(.up)))
        let startX = representation.pixelsWide - trailingWidth
        let rowByteCount = trailingWidth * bytesPerPixel
        var pixels = Data(capacity: rowByteCount * representation.pixelsHigh)
        for y in 0..<representation.pixelsHigh {
            let offset = y * representation.bytesPerRow + startX * bytesPerPixel
            pixels.append(bitmap.advanced(by: offset), count: rowByteCount)
        }
        return pixels
    }
}
