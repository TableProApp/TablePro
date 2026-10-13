//
//  ThemeTableChromeTests.swift
//  TableProTests
//
//  A content table under a default theme has to stay AppKit's own: its background, stripes, grid
//  color, scroll view material and selection. Under a theme it takes the theme's colors, and its
//  selection keeps the shape the table style gives it.
//

import AppKit
@testable import TablePro
import Testing

@MainActor
private final class ChromeTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var chrome: ThemeTableChrome?

    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ThemeTableRowView()
        rowView.chrome = chrome
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
}

/// Overriding a draw method moves a row off AppKit's update-layer path, so the native reference
/// takes the same path as `ThemeTableRowView`.
@MainActor
private final class DrawPathTableRowView: NSTableRowView {
    // swiftlint:disable:next unneeded_override
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
    }
}

/// A bitmap cache converts through its own color space, so a theme color is held to the same color
/// drawn by a plain fill into the same kind of cache.
@MainActor
private final class FillView: NSView {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

/// Each test adopts a pair on the shared `ThemeEngine` and restores it in a `defer`. The bodies are
/// synchronous and `@MainActor`, so nothing else on the main actor runs between the two.
@Suite("Content tables follow the theme", .serialized)
@MainActor
struct ThemeTableChromeTests {
    private struct Table {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: NSTableView
        let source: ChromeTableSource
    }

    private static let rowFrame = NSRect(x: 0, y: 0, width: 160, height: 24)

    private func preservingEngine(_ body: () throws -> Void) rethrows {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        try body()
    }

    private func adopt(_ overrides: [ThemeSlot: String]) throws {
        var theme = BuiltInThemes.light
        if !overrides.isEmpty {
            theme.id = "user.test.table-chrome"
            for (slot, hex) in overrides {
                theme.overrides[slot] = try ThemeColor(validating: hex)
            }
        }
        ThemeEngine.shared.adopt(ThemeSelection(
            pair: ThemePair(light: theme, dark: BuiltInThemes.dark),
            effectiveAppearance: .light
        ))
    }

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func makeTable(style: NSTableView.Style = .inset, alternates: Bool = true) -> Table {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        tableView.style = style
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = alternates
        tableView.rowHeight = 24
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.width = 200
        tableView.addTableColumn(column)

        let source = ChromeTableSource()
        tableView.dataSource = source
        tableView.delegate = source

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
        return Table(window: window, scrollView: scrollView, tableView: tableView, source: source)
    }

    private func attach(_ family: ThemeTableChrome.Family, to table: Table) -> ThemeTableChrome {
        let chrome = ThemeTableChrome(tableView: table.tableView, family: family)
        table.source.chrome = chrome
        table.tableView.reloadData()
        table.tableView.layoutSubtreeIfNeeded()
        return chrome
    }

    private func hex(_ color: NSColor?) throws -> String {
        let color = try #require(color)
        var hex = ""
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    private func pixels(of view: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func color(in rep: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        let color = try #require(rep.colorAt(x: x, y: y))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private func cached(_ fill: NSColor) throws -> NSColor {
        let view = FillView(color: fill)
        view.appearance = NSAppearance(named: .aqua)
        let rep = try pixels(of: view)
        return try color(in: rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
    }

    private func matches(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.03) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
    }

    private func selected(_ row: NSTableRowView) -> NSTableRowView {
        row.appearance = NSAppearance(named: .aqua)
        row.wantsLayer = true
        row.isSelected = true
        row.isEmphasized = true
        return row
    }

    // MARK: - Table properties

    @Test("Under the default theme the table, its stripes and its scroll view stay AppKit's own")
    func defaultThemeTouchesNothing() throws {
        try preservingEngine {
            try adopt([:])
            for family in [ThemeTableChrome.Family.records, .code] {
                let table = makeTable()
                let background = table.tableView.backgroundColor
                let gridColor = table.tableView.gridColor
                let drawsBackground = table.scrollView.drawsBackground
                let chrome = attach(family, to: table)

                #expect(table.tableView.backgroundColor === background)
                #expect(table.tableView.gridColor === gridColor)
                #expect(table.tableView.usesAlternatingRowBackgroundColors)
                #expect(table.scrollView.drawsBackground == drawsBackground)
                #expect(!chrome.isBackgroundThemed)
                #expect(chrome.rowBackgroundColor(forRow: 1) == nil)
                #expect(chrome.selectionColor(emphasized: true) == nil)
                #expect(chrome.selectionColor(emphasized: false) == nil)
            }
        }
    }

    @Test("A records table takes the grid's background, stripes and grid line, and gets its own back")
    func recordsFamilyThemesAndRestores() throws {
        try preservingEngine {
            try adopt([:])
            let table = makeTable()
            let background = table.tableView.backgroundColor
            let gridColor = table.tableView.gridColor
            let drawsBackground = table.scrollView.drawsBackground
            let chrome = attach(.records, to: table)

            try adopt([
                .gridBackground: "#FAFAFA",
                .gridAlternateRow: "#F0F0F0",
                .gridLine: "#DDDDDD",
                .gridSelection: "#C8E1FF",
                .gridInactiveSelection: "#E0E0E0",
            ])
            #expect(try hex(table.tableView.backgroundColor) == "#FAFAFA")
            #expect(try hex(table.tableView.gridColor) == "#DDDDDD")
            #expect(!table.tableView.usesAlternatingRowBackgroundColors)
            #expect(!table.scrollView.drawsBackground)
            #expect(try hex(chrome.rowBackgroundColor(forRow: 0)) == "#FAFAFA")
            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#F0F0F0")
            #expect(try hex(chrome.selectionColor(emphasized: true)) == "#C8E1FF")
            #expect(try hex(chrome.selectionColor(emphasized: false)) == "#E0E0E0")

            try adopt([:])
            #expect(table.tableView.backgroundColor == background)
            #expect(table.tableView.gridColor == gridColor)
            #expect(table.tableView.usesAlternatingRowBackgroundColors)
            #expect(table.scrollView.drawsBackground == drawsBackground)
            #expect(chrome.rowBackgroundColor(forRow: 1) == nil)
        }
    }

    @Test("A code table takes the editor's background without stripes, and the editor's selection")
    func codeFamilyUsesEditorSlots() throws {
        try preservingEngine {
            try adopt([.editorBackground: "#FDF6E3", .editorSelection: "#EEE8D5", .gridLine: "#DDDDDD"])
            let table = makeTable()
            let gridColor = table.tableView.gridColor
            let chrome = attach(.code, to: table)

            #expect(try hex(table.tableView.backgroundColor) == "#FDF6E3")
            #expect(!table.tableView.usesAlternatingRowBackgroundColors)
            #expect(table.tableView.gridColor === gridColor)
            #expect(try hex(chrome.rowBackgroundColor(forRow: 0)) == "#FDF6E3")
            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#FDF6E3")
            #expect(try hex(chrome.selectionColor(emphasized: true)) == "#EEE8D5")
            #expect(try hex(chrome.selectionColor(emphasized: false)) == "#EEE8D5")
        }
    }

    @Test("A table that did not stripe stays unstriped under a theme")
    func unstripedTableStaysSolid() throws {
        try preservingEngine {
            try adopt([.gridBackground: "#FAFAFA", .gridAlternateRow: "#F0F0F0"])
            let table = makeTable(alternates: false)
            let chrome = attach(.records, to: table)

            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#FAFAFA")
            try adopt([:])
            #expect(!table.tableView.usesAlternatingRowBackgroundColors)
        }
    }

    // MARK: - Row drawing

    @Test("Under the default theme a selected row draws exactly what NSTableRowView draws")
    func defaultSelectionIsNative() throws {
        try preservingEngine {
            try adopt([:])
            let table = makeTable()
            let chrome = attach(.records, to: table)
            let row = ThemeTableRowView(frame: Self.rowFrame)
            row.chrome = chrome
            let stockRow = DrawPathTableRowView(frame: Self.rowFrame)

            let themed = try pixels(of: selected(row))
            let stock = try pixels(of: selected(stockRow))
            let x = themed.pixelsWide / 2
            let y = themed.pixelsHigh / 2
            #expect(matches(try color(in: themed, x: x, y: y), try color(in: stock, x: x, y: y)))
            #expect(row.interiorBackgroundStyle == stockRow.interiorBackgroundStyle)
            withExtendedLifetime(chrome) {}
        }
    }

    @Test("A theme's selection fills the row and keeps the row's text unflipped")
    func themedSelectionDraws() throws {
        try preservingEngine {
            try adopt([.gridSelection: "#FF00FF"])
            let table = makeTable()
            let chrome = attach(.records, to: table)
            let row = ThemeTableRowView(frame: Self.rowFrame)
            row.chrome = chrome

            let rep = try pixels(of: selected(row))
            let center = try color(in: rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
            let magenta = try cached(HexColor.color("#FF00FF"))
            #expect(matches(center, magenta), "drew \(center), theme \(magenta)")
            #expect(row.interiorBackgroundStyle == .normal)
            withExtendedLifetime(chrome) {}
        }
    }

    /// The theme recolors AppKit's selection rather than replacing it, so an inset table's rounded,
    /// inset selection covers the same pixels with either color.
    @Test("A themed selection covers the same pixels as AppKit's in an inset table")
    func themedSelectionKeepsTheInsetShape() throws {
        try preservingEngine {
            try adopt([:])
            let nativeTable = makeTable(style: .inset, alternates: false)
            let nativeChrome = attach(.records, to: nativeTable)
            let native = try selectedRowPixels(in: nativeTable)
            let accent = try color(in: native, x: native.pixelsWide / 2, y: native.pixelsHigh / 2)

            try adopt([.gridSelection: "#FF00FF"])
            let themedTable = makeTable(style: .inset, alternates: false)
            let themedChrome = attach(.records, to: themedTable)
            let themed = try selectedRowPixels(in: themedTable)
            withExtendedLifetime((nativeChrome, themedChrome)) {}
            let magenta = try color(in: themed, x: themed.pixelsWide / 2, y: themed.pixelsHigh / 2)
            #expect(!matches(magenta, accent))
            #expect(magenta.redComponent > 0.8 && magenta.greenComponent < 0.5 && magenta.blueComponent > 0.8, "\(magenta)")

            let middle = native.pixelsHigh / 2
            var nativeCovered = 0
            var themedCovered = 0
            for x in 0..<native.pixelsWide {
                if matches(try color(in: native, x: x, y: middle), accent) { nativeCovered += 1 }
                if matches(try color(in: themed, x: x, y: middle), magenta) { themedCovered += 1 }
            }
            #expect(nativeCovered > 0)
            #expect(abs(nativeCovered - themedCovered) <= 2, "native \(nativeCovered), themed \(themedCovered)")
            #expect(
                matches(try color(in: native, x: 0, y: middle), accent) == matches(try color(in: themed, x: 0, y: middle), magenta)
            )
        }
    }

    private func selectedRowPixels(in table: Table) throws -> NSBitmapImageRep {
        table.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let row = try #require(table.tableView.rowView(atRow: 0, makeIfNecessary: true))
        row.isEmphasized = true
        row.layoutSubtreeIfNeeded()
        return try pixels(of: row)
    }
}
