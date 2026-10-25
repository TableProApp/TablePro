// The theme editor renders a draft through a fixed scope: it draws the draft and leaves the engine alone.

import AppKit
import Combine
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ThemeScopeTests {
    private struct Table {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: NSTableView
    }

    // Never ordered front and never closed: `close()` on a test window over-releases it.
    private func makeTable() -> Table {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.width = 200
        tableView.addTableColumn(column)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView
        return Table(window: window, scrollView: scrollView, tableView: tableView)
    }

    private static func draft() throws -> ThemeDefinition {
        ThemeDefinition(
            id: "user.draft",
            name: "Draft",
            author: "",
            appearance: .dark,
            overrides: [
                .gridBackground: try ThemeColor(validating: "#282A36"),
                .gridSelection: try ThemeColor(validating: "#6272A4"),
                .editorSelection: try ThemeColor(validating: "#44475A"),
                .editorBackground: try ThemeColor(validating: "#1B3A2C"),
                .editorText: try ThemeColor(validating: "#F8F8F2"),
            ]
        )
    }

    @Test("A fixed scope drives a table's chrome from its definition, in either appearance, without the engine")
    func fixedScopeDrivesTheTableChrome() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let engine = ThemeEngine.shared
            let pairBefore = engine.pair
            let revisionBefore = engine.revision
            let table = makeTable()
            let scope = ThemeScope.fixed(try Self.draft())

            let chrome = ThemeTableChrome(tableView: table.tableView, family: .records, scope: scope)

            #expect(chrome.isBackgroundThemed)
            #expect(chrome.themesRows)
            #expect(ThemeTestFixture.hex(table.tableView.backgroundColor, in: .aqua) == "#282A36")
            #expect(ThemeTestFixture.hex(table.tableView.backgroundColor, in: .darkAqua) == "#282A36")
            #expect(ThemeTestFixture.hex(chrome.rowBackgroundColor(forRow: 1), in: .aqua) == "#31333E")
            #expect(ThemeTestFixture.hex(chrome.selectionColor(emphasized: true)) == "#6272A4")
            #expect(chrome.selectionColor(emphasized: false) === NSColor.unemphasizedSelectedContentBackgroundColor)
            #expect(!table.scrollView.drawsBackground)
            #expect(engine.pair == pairBefore)
            #expect(engine.revision == revisionBefore)
            withExtendedLifetime(chrome) {}
        }
    }

    @Test("A live theme change leaves a fixed-scope table alone")
    func liveChangesDoNotReachAFixedScope() throws {
        try ThemeTestFixture.preservingEngine {
            ThemeTestFixture.adopt(.builtIn, appearance: .light)
            let table = makeTable()
            let chrome = ThemeTableChrome(tableView: table.tableView, family: .records, scope: .fixed(try Self.draft()))

            try ThemeTestFixture.adopt([.gridBackground: "#FAFAFA"], appearance: .light)
            chrome.apply()

            #expect(ThemeTestFixture.hex(table.tableView.backgroundColor, in: .aqua) == "#282A36")
            withExtendedLifetime(chrome) {}
        }
    }

    @Test("A fixed scope drives a code table's selection from its definition")
    func fixedScopeDrivesACodeTableSelection() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let table = makeTable()
            let chrome = ThemeTableChrome(tableView: table.tableView, family: .code, scope: .fixed(try Self.draft()))

            #expect(ThemeTestFixture.hex(chrome.selectionColor(emphasized: true)) == "#44475A")
            #expect(ThemeTestFixture.hex(table.tableView.backgroundColor, in: .aqua) == "#1B3A2C")
            withExtendedLifetime(chrome) {}
        }
    }

    @Test("A fixed scope drives a text view's colors")
    func fixedScopeDrivesATextView() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            let style = ThemeTextViewStyle(textView: textView, scope: .fixed(try Self.draft()))

            #expect(ThemeTestFixture.hex(textView.backgroundColor, in: .aqua) == "#1B3A2C")
            #expect(ThemeTestFixture.hex(textView.textColor, in: .aqua) == "#F8F8F2")

            style.detach()
            #expect(ThemeTestFixture.hex(textView.backgroundColor, in: .aqua) == ThemeTestFixture.hex(.textBackgroundColor, in: .aqua))
        }
    }

    @Test("A fixed scope reports the definition and never a change")
    func fixedScopeIsConstant() throws {
        let draft = try Self.draft()
        let scope = ThemeScope.fixed(draft)
        var received = 0
        let cancellable = scope.changes.sink { _ in received += 1 }

        try ThemeTestFixture.adopting([.gridBackground: "#FAFAFA"], appearance: .light) {
            #expect(scope.activeTheme == draft)
            #expect(scope.resolved.definition == draft)
            #expect(ThemeTestFixture.hex(scope.palette[.gridBackground], in: .aqua) == "#282A36")
        }
        #expect(received == 0)
        withExtendedLifetime(cancellable) {}
    }

    @Test("The live scope is the engine")
    func liveScopeForwardsToTheEngine() throws {
        try ThemeTestFixture.adopting([.gridBackground: "#FAFAFA"], appearance: .light) {
            let engine = ThemeEngine.shared
            #expect(ThemeScope.live.activeTheme == engine.activeTheme)
            #expect(ThemeScope.live.resolved == engine.resolved)
            #expect(ThemeScope.live.palette.revision == engine.palette.revision)
        }
    }

    @Test("A fixed palette never shares a color name with the live palette")
    func fixedPaletteIsNamedApart() throws {
        let fixed = ThemeScope.fixed(try Self.draft()).palette[.gridBackground]
        let live = ThemeEngine.shared.palette[.gridBackground]
        #expect(fixed != live)
    }
}
