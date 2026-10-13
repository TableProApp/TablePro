//
//  PrivilegeScopeOutlineThemeTests.swift
//  TableProTests
//
//  The privilege scope outline is a content table, so it takes the data grid's colors and text under
//  a theme and stays exactly AppKit's, row views included, under a default one.
//

import AppKit
import Combine
@testable import TablePro
import TableProPluginKit
import Testing

/// Each test adopts a pair on the shared `ThemeEngine` and restores it in a `defer`. The bodies are
/// synchronous and `@MainActor`, so nothing else on the main actor runs between the two.
@Suite("Privilege scope outline follows the theme", .serialized)
@MainActor
struct PrivilegeScopeOutlineThemeTests {
    private struct Mounted {
        let window: NSWindow
        let scrollView: NSScrollView
        let outline: PrivilegeScopeOutline
        let coordinator: PrivilegeScopeOutlineCoordinator
    }

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func mount() throws -> Mounted {
        let viewModel = UsersRolesViewModel(connectionId: UUID(), databaseType: .postgresql)
        viewModel.privilegeTree.showGrantedOnly(scopes: [.database("app"), .database("web")])
        let coordinator = PrivilegeScopeOutlineCoordinator(viewModel: viewModel)
        let scrollView = PrivilegeScopeOutlineView.makeScrollView(coordinator: coordinator)
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView
        let outline = try #require(scrollView.documentView as? PrivilegeScopeOutline)
        outline.reloadData()
        outline.layoutSubtreeIfNeeded()
        return Mounted(window: window, scrollView: scrollView, outline: outline, coordinator: coordinator)
    }

    private func hex(_ color: NSColor?) throws -> String {
        let color = try #require(color)
        var hex = ""
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    @Test("Under the default theme the outline keeps AppKit's background, stripes and selection")
    func defaultThemeTouchesNothing() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let mounted = try mount()
            let chrome = try #require(mounted.outline.themeChrome)

            let stock = NSOutlineView()
            stock.style = .fullWidth
            #expect(mounted.outline.backgroundColor == stock.backgroundColor)
            #expect(mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(!mounted.scrollView.drawsBackground)
            #expect(!chrome.isBackgroundThemed)
            #expect(chrome.selectionColor(emphasized: true) == nil)
            #expect(mounted.outline.numberOfRows == 2)
            for row in 0 ..< mounted.outline.numberOfRows {
                let rowView = try #require(mounted.outline.rowView(atRow: row, makeIfNecessary: true))
                #expect(type(of: rowView) == NSTableRowView.self)
            }
        }
    }

    @Test("A theme's selection swaps in themed rows and a default theme swaps AppKit's back, keeping the selection")
    func rowClassFollowsTheTheme() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let mounted = try mount()
            let chrome = try #require(mounted.outline.themeChrome)
            mounted.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let selectedScopes = mounted.coordinator.viewModel.selectedScopes
            #expect(selectedScopes.count == 1)
            _ = try #require(mounted.outline.rowView(atRow: 1, makeIfNecessary: true))

            var published = 0
            let subscription = mounted.coordinator.viewModel.$selectedScopes.dropFirst().sink { _ in published += 1 }
            defer { subscription.cancel() }

            try ThemeTestFixture.adopt([.gridSelection: "#C8E1FF"], appearance: .light)
            let themed = try #require(mounted.outline.rowView(atRow: 1, makeIfNecessary: true) as? ThemeTableRowView)
            #expect(themed.chrome === chrome)
            #expect(mounted.outline.selectedRowIndexes == IndexSet(integer: 1))

            try ThemeTestFixture.adopt([:], appearance: .light)
            let native = try #require(mounted.outline.rowView(atRow: 1, makeIfNecessary: true))
            #expect(type(of: native) == NSTableRowView.self)
            #expect(mounted.outline.selectedRowIndexes == IndexSet(integer: 1))
            #expect(mounted.coordinator.viewModel.selectedScopes == selectedScopes)
            #expect(published == 0, "the rebuild republished the selection \(published) times")
        }
    }

    @Test("Both columns are records cells, told when their row sits on the theme's selection")
    func cellsFollowTheThemedSelection() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.gridSelection: "#C8E1FF"], appearance: .light)
            let mounted = try mount()
            mounted.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let row = try #require(mounted.outline.rowView(atRow: 0, makeIfNecessary: true) as? ThemeTableRowView)
            row.isEmphasized = true

            for column in 0 ..< mounted.outline.numberOfColumns {
                let selected = mounted.outline.view(atColumn: column, row: 0, makeIfNecessary: true)
                let other = mounted.outline.view(atColumn: column, row: 1, makeIfNecessary: true)
                #expect((selected as? ThemeTableChrome.HostingCell)?.isOnThemedSelection == true)
                #expect((other as? ThemeTableChrome.HostingCell)?.isOnThemedSelection == false)
            }
        }
    }

    @Test("Under a theme the outline takes the grid's background, stripes and selection, and gets its own back")
    func themeAppliesAndRestores() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let mounted = try mount()
            let chrome = try #require(mounted.outline.themeChrome)
            let background = mounted.outline.backgroundColor

            try ThemeTestFixture.adopt([
                .gridBackground: "#FAFAFA",
                .gridAlternateRow: "#F0F0F0",
                .gridSelection: "#C8E1FF",
            ], appearance: .light)
            #expect(try hex(mounted.outline.backgroundColor) == "#FAFAFA")
            #expect(!mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(try hex(chrome.rowBackgroundColor(forRow: 0)) == "#FAFAFA")
            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#F0F0F0")
            #expect(try hex(chrome.selectionColor(emphasized: true)) == "#C8E1FF")

            try ThemeTestFixture.adopt([:], appearance: .light)
            #expect(mounted.outline.backgroundColor == background)
            #expect(mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(!mounted.scrollView.drawsBackground)
            #expect(chrome.rowBackgroundColor(forRow: 1) == nil)
        }
    }
}
