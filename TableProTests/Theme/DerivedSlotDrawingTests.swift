//
//  DerivedSlotDrawingTests.swift
//  TableProTests
//
//  A theme that sets only the grid background used to stripe its odd rows in the system's opaque
//  light stripe and keep a white header over its own color. The stripe and header now come from the
//  theme's background, and the selection text from the theme's own selection and text.
//

import AppKit
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct DerivedSlotDrawingTests {
    private func stripedTable() -> NSTableView {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tableView.usesAlternatingRowBackgroundColors = true
        return tableView
    }

    // MARK: - Grid stripes and header

    @Test("A background-only light theme stripes and heads the grid from its own background")
    func backgroundOnlyLightGrid() throws {
        try ThemeTestFixture.adopting([.gridBackground: "#FDF6E3"], appearance: .light) {
            let tableView = stripedTable()

            #expect(ThemeTestFixture.hex(DataGridBodyChrome.stripeColor(forRow: 0, of: tableView, scope: .live)) == "#FDF6E3")
            #expect(ThemeTestFixture.hex(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView, scope: .live)) == "#F3ECDA")
            #expect(ThemeTestFixture.hex(SortableHeaderChrome.backgroundColor(scope: .live)) == "#FDF6E3")
        }
    }

    @Test("A background-only dark theme stripes toward white")
    func backgroundOnlyDarkGrid() throws {
        try ThemeTestFixture.adopting([.gridBackground: "#282A36"], appearance: .dark) {
            let tableView = stripedTable()

            #expect(ThemeTestFixture.hex(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView, scope: .live), in: .darkAqua) == "#31333E")
            #expect(ThemeTestFixture.hex(SortableHeaderChrome.backgroundColor(scope: .live), in: .darkAqua) == "#282A36")
        }
    }

    @Test("Under the default pair the stripe and the header stay the system's own objects")
    func defaultStripeAndHeaderAreNative() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let tableView = stripedTable()

            #expect(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView, scope: .live) === NativeThemeColors.alternateRow)
            #expect(SortableHeaderChrome.backgroundColor(scope: .live) === NSColor.controlBackgroundColor)
        }
    }

    @Test("A records table stripes a background-only theme from its own background too")
    func recordsTableStripes() throws {
        try ThemeTestFixture.adopting([.gridBackground: "#FDF6E3"], appearance: .light) {
            let tableView = stripedTable()
            let scrollView = NSScrollView(frame: tableView.frame)
            scrollView.documentView = tableView
            let chrome = ThemeTableChrome(tableView: tableView, family: .records)

            #expect(ThemeTestFixture.hex(chrome.rowBackgroundColor(forRow: 1)) == "#F3ECDA")
            #expect(ThemeTestFixture.hex(chrome.rowBackgroundColor(forRow: 2)) == "#FDF6E3")
        }
    }

    // MARK: - Cell palette

    private func cellPalette() throws -> DataGridCellPalette {
        let aqua = try #require(NSAppearance(named: .aqua))
        return ThemeScope.live.dataGridCellPalette(in: aqua)
    }

    @Test("Over a themed selection the cell text takes the theme's grid text when it has no selection text")
    func selectionTextFollowsThemedText() throws {
        try ThemeTestFixture.adopting([.gridSelection: "#44475A", .gridText: "#F8F8F2"], appearance: .light) {
            let palette = try cellPalette()
            #expect(ThemeTestFixture.hex(palette.selectionText) == "#F8F8F2")
        }
    }

    @Test("Over a themed selection with native text the cell text is the native label color")
    func selectionTextFollowsNativeText() throws {
        try ThemeTestFixture.adopting([.gridSelection: "#44475A"], appearance: .light) {
            let palette = try cellPalette()
            #expect(palette.selectionText === NSColor.labelColor)
        }
    }

    @Test("A selection text with no themed selection leaves AppKit's white selection text")
    func selectionTextWithoutASelectionIsNative() throws {
        try ThemeTestFixture.adopting([.gridSelectionText: "#00FF00", .gridText: "#112233"], appearance: .light) {
            let palette = try cellPalette()
            #expect(palette.selectionText === NSColor.alternateSelectedControlTextColor)
        }
    }

    @Test("Bools follow the theme's grid text")
    func boolsFollowThemedText() throws {
        try ThemeTestFixture.adopting([.gridText: "#112233"], appearance: .light) {
            let palette = try cellPalette()
            #expect(ThemeTestFixture.hex(palette.booleanTrueText) == "#112233")
            #expect(ThemeTestFixture.hex(palette.booleanFalseText) == "#112233")
        }
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let palette = try cellPalette()
            #expect(palette.booleanTrueText === NSColor.labelColor)
        }
    }
}
