import AppKit
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct DerivedSlotDrawingTests {
    private func recordsTable() -> (NSTableView, NSScrollView) {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tableView.usesAlternatingRowBackgroundColors = true
        let scrollView = NSScrollView(frame: tableView.frame)
        scrollView.documentView = tableView
        return (tableView, scrollView)
    }

    // MARK: - Stripes

    @Test("A light background-only theme stripes a records table from its own background")
    func recordsTableStripes() throws {
        try ThemeTestFixture.adopting([.gridBackground: "#FDF6E3"], appearance: .light) {
            let (tableView, scrollView) = recordsTable()
            let chrome = ThemeTableChrome(tableView: tableView, family: .records)

            #expect(ThemeTestFixture.hex(chrome.rowBackgroundColor(forRow: 1)) == "#F3ECDA")
            #expect(ThemeTestFixture.hex(chrome.rowBackgroundColor(forRow: 2)) == "#FDF6E3")
            withExtendedLifetime(scrollView) {}
        }
    }

    @Test("A dark background-only theme stripes a records table toward white")
    func recordsTableStripesTowardWhite() throws {
        try ThemeTestFixture.adopting([.gridBackground: "#282A36"], appearance: .dark) {
            let (tableView, scrollView) = recordsTable()
            let chrome = ThemeTableChrome(tableView: tableView, family: .records)

            #expect(ThemeTestFixture.hex(chrome.rowBackgroundColor(forRow: 1), in: .darkAqua) == "#31333E")
            withExtendedLifetime(scrollView) {}
        }
    }

    // MARK: - Cell palette

    private func cellPalette() throws -> DataGridCellPalette {
        let aqua = try #require(NSAppearance(named: .aqua))
        return ThemeScope.live.dataGridCellPalette(in: aqua)
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
