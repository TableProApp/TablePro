import AppKit
@testable import TablePro
import TableProTheme
import Testing

@MainActor
private final class HeaderTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
}

@MainActor
struct ThemeTableHeaderTests {
    private struct Table {
        let window: NSWindow
        let tableView: NSTableView
        let header: NSTableHeaderView
        let corner: NSView?
        let source: HeaderTableSource
    }

    // Never ordered front and never closed: `close()` on a test window over-releases it.
    private func makeTable() -> Table {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let header = NSTableHeaderView()
        tableView.headerView = header
        for title in ["Operation", "Cost"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = 140
            tableView.addTableColumn(column)
        }
        let source = HeaderTableSource()
        tableView.dataSource = source
        tableView.delegate = source

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView
        tableView.reloadData()
        return Table(window: window, tableView: tableView, header: header, corner: tableView.cornerView, source: source)
    }

    private static let fullTheme: [ThemeSlot: String] = [
        .gridBackground: "#21222C",
        .gridText: "#F8F8F2",
        .gridAlternateRow: "#282A36",
        .gridLine: "#44475A",
        .editorBackground: "#282A36",
        .editorText: "#F8F8F2",
        .editorSelection: "#44475A",
    ]

    @Test("Under the default theme a table keeps the header and corner its owner installed")
    func defaultThemeKeepsTheOwnersHeader() throws {
        for family in [ThemeTableChrome.Family.records, .code] {
            let table = makeTable()
            let chrome = ThemeTableChrome(tableView: table.tableView, family: family, scope: .fixed(BuiltInThemes.light))

            #expect(table.tableView.headerView === table.header)
            #expect(table.tableView.cornerView === table.corner)
            withExtendedLifetime(chrome) {}
            withExtendedLifetime(table.window) {}
        }
    }

    @Test("A theme that colors every content slot leaves the header and corner to AppKit")
    func themeLeavesTheHeaderToAppKit() throws {
        try ThemeTestFixture.preservingEngine {
            for family in [ThemeTableChrome.Family.records, .code] {
                try ThemeTestFixture.adopt(Self.fullTheme, appearance: .light)
                let table = makeTable()
                let chrome = ThemeTableChrome(tableView: table.tableView, family: family)

                #expect(chrome.isBackgroundThemed)
                #expect(table.tableView.headerView === table.header)
                #expect(table.tableView.cornerView === table.corner)

                ThemeTestFixture.adopt(.builtIn, appearance: .light)
                chrome.apply()
                #expect(table.tableView.headerView === table.header)
                #expect(table.tableView.cornerView === table.corner)
                withExtendedLifetime(table.window) {}
            }
        }
    }
}
