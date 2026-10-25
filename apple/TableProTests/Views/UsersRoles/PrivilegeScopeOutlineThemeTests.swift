import AppKit
import Combine
@testable import TablePro
import TableProPluginKit
import TableProTheme
import Testing

// Each body is synchronous and `@MainActor`, so nothing else runs under the pair it adopts on the shared engine.
@MainActor
struct PrivilegeScopeOutlineThemeTests {
    private struct Mounted {
        let window: NSWindow
        let scrollView: NSScrollView
        let outline: PrivilegeScopeOutline
        let coordinator: PrivilegeScopeOutlineCoordinator
    }

    // Never ordered front and never closed: `close()` on a test window over-releases it.
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

    @Test("Under the default theme the outline keeps AppKit's background and stripes, and its rows draw the system selection")
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
            #expect(chrome.selectionColor(emphasized: true) === NSColor.selectedContentBackgroundColor)
            #expect(chrome.selectionColor(emphasized: false) === NSColor.unemphasizedSelectedContentBackgroundColor)
            #expect(mounted.outline.numberOfRows == 2)
            for row in 0 ..< mounted.outline.numberOfRows {
                let rowView = try #require(mounted.outline.rowView(atRow: row, makeIfNecessary: true) as? ThemeTableRowView)
                #expect(rowView.chrome === chrome)
            }
        }
    }

    @Test("A theme change restyles the rows in place, keeping the selection")
    func rowsSurviveThemeChanges() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let mounted = try mount()
            let chrome = try #require(mounted.outline.themeChrome)
            mounted.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let selectedScopes = mounted.coordinator.viewModel.selectedScopes
            #expect(selectedScopes.count == 1)
            let row = try #require(mounted.outline.rowView(atRow: 1, makeIfNecessary: true) as? ThemeTableRowView)

            var published = 0
            let subscription = mounted.coordinator.viewModel.$selectedScopes.dropFirst().sink { _ in published += 1 }
            defer { subscription.cancel() }

            try ThemeTestFixture.adopt([.gridBackground: "#FAFAFA", .gridSelection: "#C8E1FF"], appearance: .light)
            #expect(mounted.outline.rowView(atRow: 1, makeIfNecessary: true) === row)
            #expect(row.chrome === chrome)
            #expect(mounted.outline.selectedRowIndexes == IndexSet(integer: 1))

            try ThemeTestFixture.adopt([:], appearance: .light)
            #expect(mounted.outline.rowView(atRow: 1, makeIfNecessary: true) === row)
            #expect(mounted.outline.selectedRowIndexes == IndexSet(integer: 1))
            #expect(mounted.coordinator.viewModel.selectedScopes == selectedScopes)
            #expect(published == 0, "the theme change republished the selection \(published) times")
        }
    }

    @Test("Both columns are records cells")
    func bothColumnsAreRecordsCells() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.gridBackground: "#FAFAFA"], appearance: .light)
            let mounted = try mount()

            for column in 0 ..< mounted.outline.numberOfColumns {
                for row in 0 ..< mounted.outline.numberOfRows {
                    #expect(mounted.outline.view(atColumn: column, row: row, makeIfNecessary: true) is ThemeTableChrome.HostingCell)
                }
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
                .gridInactiveSelection: "#E0E0E0",
            ], appearance: .light)
            #expect(try hex(mounted.outline.backgroundColor) == "#FAFAFA")
            #expect(!mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(try hex(chrome.rowBackgroundColor(forRow: 0)) == "#FAFAFA")
            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#F0F0F0")
            #expect(try hex(chrome.selectionColor(emphasized: true)) == "#C8E1FF")
            #expect(try hex(chrome.selectionColor(emphasized: false)) == "#E0E0E0")

            try ThemeTestFixture.adopt([:], appearance: .light)
            #expect(mounted.outline.backgroundColor == background)
            #expect(mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(!mounted.scrollView.drawsBackground)
            #expect(chrome.rowBackgroundColor(forRow: 1) == nil)
            #expect(chrome.selectionColor(emphasized: true) === NSColor.selectedContentBackgroundColor)
        }
    }

    @Test("The outline's header is a theme header, and both columns theme header cells")
    func headerIsAThemeHeader() throws {
        let mounted = try mount()

        #expect(mounted.outline.headerView is ThemeTableHeaderView)
        #expect(mounted.outline.tableColumns.count == 2)
        #expect(mounted.outline.tableColumns.allSatisfy { $0.headerCell is ThemeTableHeaderCell })
    }
}
