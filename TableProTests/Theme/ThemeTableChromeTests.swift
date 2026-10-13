//
//  ThemeTableChromeTests.swift
//  TableProTests
//
//  A content table under a default theme has to stay AppKit's own: its background, stripes, grid
//  color, scroll view material, row view class and selection. Under a theme it takes the theme's
//  colors, its selection keeps the shape the table style gives it, and its records cells take the
//  theme's text.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class ChromeTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let cellIdentifier = NSUserInterfaceItemIdentifier("value")

    weak var chrome: ThemeTableChrome?
    var rowCount = 3
    var vendsCells = false

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        chrome?.makeRowView(in: tableView)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard vendsCells else { return nil }
        return ThemeTableChrome.HostingCell.make(Self.cellIdentifier, in: tableView, showing: Text("Row \(row)"))
    }
}

/// The table every content table was before the theme reached it: no row view delegate at all.
@MainActor
private final class StockTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
}

/// The themed row recolors what `drawSelection(in:)` draws, so the selection's shape is held to that
/// method's own output. A row without the override draws through its layer, which a bitmap cache
/// captures at full width.
@MainActor
private final class DrawPathTableRowView: NSTableRowView {
    // swiftlint:disable:next unneeded_override
    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
    }
}

@MainActor
private final class DrawPathTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { DrawPathTableRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
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
        let delegate: AnyObject

        var source: ChromeTableSource? { delegate as? ChromeTableSource }
    }

    private static let rowFrame = NSRect(x: 0, y: 0, width: 160, height: 24)

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func makeTable(
        style: NSTableView.Style = .inset,
        alternates: Bool = true,
        source: (NSObject & NSTableViewDataSource & NSTableViewDelegate)? = nil
    ) -> Table {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        tableView.style = style
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = alternates
        tableView.rowHeight = 24
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.width = 200
        tableView.addTableColumn(column)

        let source = source ?? ChromeTableSource()
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
        return Table(window: window, scrollView: scrollView, tableView: tableView, delegate: source)
    }

    private func attach(_ family: ThemeTableChrome.Family, to table: Table) -> ThemeTableChrome {
        let chrome = ThemeTableChrome(tableView: table.tableView, family: family)
        table.source?.chrome = chrome
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
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
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
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let table = makeTable()
            let background = table.tableView.backgroundColor
            let gridColor = table.tableView.gridColor
            let drawsBackground = table.scrollView.drawsBackground
            let chrome = attach(.records, to: table)

            try ThemeTestFixture.adopt([
                .gridBackground: "#FAFAFA",
                .gridAlternateRow: "#F0F0F0",
                .gridLine: "#DDDDDD",
                .gridSelection: "#C8E1FF",
                .gridInactiveSelection: "#E0E0E0",
            ], appearance: .light)
            #expect(try hex(table.tableView.backgroundColor) == "#FAFAFA")
            #expect(try hex(table.tableView.gridColor) == "#DDDDDD")
            #expect(!table.tableView.usesAlternatingRowBackgroundColors)
            #expect(!table.scrollView.drawsBackground)
            #expect(try hex(chrome.rowBackgroundColor(forRow: 0)) == "#FAFAFA")
            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#F0F0F0")
            #expect(try hex(chrome.selectionColor(emphasized: true)) == "#C8E1FF")
            #expect(try hex(chrome.selectionColor(emphasized: false)) == "#E0E0E0")

            try ThemeTestFixture.adopt([:], appearance: .light)
            #expect(table.tableView.backgroundColor == background)
            #expect(table.tableView.gridColor == gridColor)
            #expect(table.tableView.usesAlternatingRowBackgroundColors)
            #expect(table.scrollView.drawsBackground == drawsBackground)
            #expect(chrome.rowBackgroundColor(forRow: 1) == nil)
        }
    }

    @Test("A code table takes the editor's background without stripes, and the editor's selection")
    func codeFamilyUsesEditorSlots() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.editorBackground: "#FDF6E3", .editorSelection: "#EEE8D5", .gridLine: "#DDDDDD"], appearance: .light)
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
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.gridBackground: "#FAFAFA", .gridAlternateRow: "#F0F0F0"], appearance: .light)
            let table = makeTable(alternates: false)
            let chrome = attach(.records, to: table)

            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#FAFAFA")
            try ThemeTestFixture.adopt([:], appearance: .light)
            #expect(!table.tableView.usesAlternatingRowBackgroundColors)
        }
    }

    // MARK: - Row drawing

    @Test("Under the default theme the rows are AppKit's own row view and draw what a stock table draws")
    func defaultRowsAreNative() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let table = makeTable(alternates: false)
            let chrome = attach(.records, to: table)
            let stock = makeTable(alternates: false, source: StockTableSource())
            stock.tableView.reloadData()
            stock.tableView.layoutSubtreeIfNeeded()

            #expect(!chrome.themesRows)
            #expect(chrome.makeRowView(in: table.tableView) == nil)
            let row = try #require(table.tableView.rowView(atRow: 0, makeIfNecessary: true))
            let stockRow = try #require(stock.tableView.rowView(atRow: 0, makeIfNecessary: true))
            #expect(type(of: row) == NSTableRowView.self)
            #expect(type(of: row) == type(of: stockRow))

            let themed = try selectedRowPixels(in: table)
            let native = try selectedRowPixels(in: stock)
            let x = native.pixelsWide / 2
            let y = native.pixelsHigh / 2
            #expect(matches(try color(in: themed, x: x, y: y), try color(in: native, x: x, y: y)))
            #expect(row.interiorBackgroundStyle == stockRow.interiorBackgroundStyle)
        }
    }

    @Test("A theme that draws the rows swaps in the themed row class, and a default theme swaps AppKit's back")
    func rowClassFollowsTheTheme() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let source = ChromeTableSource()
            source.rowCount = 40
            let table = makeTable(source: source)
            let chrome = attach(.records, to: table)
            table.tableView.selectRowIndexes(IndexSet(integer: 12), byExtendingSelection: false)
            table.tableView.scroll(NSPoint(x: 0, y: 240))
            table.tableView.layoutSubtreeIfNeeded()
            let origin = table.scrollView.contentView.bounds.origin
            #expect(origin.y > 0)
            #expect(type(of: try #require(table.tableView.rowView(atRow: 12, makeIfNecessary: true))) == NSTableRowView.self)

            for overrides in [[ThemeSlot.gridSelection: "#C8E1FF"], [.gridInactiveSelection: "#E0E0E0"], [.gridBackground: "#FAFAFA"]] {
                try ThemeTestFixture.adopt(overrides, appearance: .light)
                #expect(chrome.themesRows)
                let themedRow = try #require(table.tableView.rowView(atRow: 12, makeIfNecessary: true) as? ThemeTableRowView)
                #expect(themedRow.chrome === chrome)
                #expect(table.tableView.selectedRowIndexes == IndexSet(integer: 12))
                #expect(table.scrollView.contentView.bounds.origin == origin)

                try ThemeTestFixture.adopt([:], appearance: .light)
                #expect(!chrome.themesRows)
                #expect(type(of: try #require(table.tableView.rowView(atRow: 12, makeIfNecessary: true))) == NSTableRowView.self)
                #expect(table.tableView.selectedRowIndexes == IndexSet(integer: 12))
                #expect(table.scrollView.contentView.bounds.origin == origin)
            }
        }
    }

    @Test("A theme that only colors the grid text or lines keeps AppKit's row view")
    func textOnlyThemeKeepsNativeRows() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let table = makeTable()
            let chrome = attach(.records, to: table)

            try ThemeTestFixture.adopt([.gridText: "#112233", .gridLine: "#DDDDDD", .gridSelectionText: "#FFFFFF"], appearance: .light)
            #expect(!chrome.themesRows)
            #expect(type(of: try #require(table.tableView.rowView(atRow: 0, makeIfNecessary: true))) == NSTableRowView.self)
        }
    }

    @Test("A theme's selection fills the row and keeps the row's text unflipped")
    func themedSelectionDraws() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.gridSelection: "#FF00FF"], appearance: .light)
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
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let nativeTable = makeTable(style: .inset, alternates: false, source: DrawPathTableSource())
            nativeTable.tableView.reloadData()
            nativeTable.tableView.layoutSubtreeIfNeeded()
            let native = try selectedRowPixels(in: nativeTable)
            let accent = try color(in: native, x: native.pixelsWide / 2, y: native.pixelsHigh / 2)

            try ThemeTestFixture.adopt([.gridSelection: "#FF00FF"], appearance: .light)
            let themedTable = makeTable(style: .inset, alternates: false)
            let themedChrome = attach(.records, to: themedTable)
            let themed = try selectedRowPixels(in: themedTable)
            withExtendedLifetime(themedChrome) {}
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

    // MARK: - Records cell text

    private static let swatchID = NSUserInterfaceItemIdentifier("swatch")

    /// A shape fills with the foreground style, so its pixels are the text color without glyph edges.
    private func swatchCell(in table: Table) -> ThemeTableChrome.HostingCell {
        ThemeTableChrome.HostingCell.make(Self.swatchID, in: table.tableView, showing: Rectangle().frame(width: 8, height: 8))
    }

    private func center(_ view: some View) throws -> NSColor {
        try ThemeTestFixture.color(of: view, at: CGPoint(x: 0.5, y: 0.5), colorScheme: .light)
    }

    private func reference(_ hex: String) throws -> NSColor {
        try center(Rectangle().fill(Color(nsColor: HexColor.color(hex))).frame(width: 8, height: 8))
    }

    private var plainSwatch: some View {
        Rectangle().frame(width: 8, height: 8)
    }

    @Test("Text slots resolve: grid text by default, selection text on a theme's selection, none on AppKit's")
    func recordsTextSlotFollowsTheRow() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: false, onEmphasizedSelection: false, highContrast: false) == nil)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: true, onEmphasizedSelection: false, highContrast: false) == nil)

            try ThemeTestFixture.adopt([.gridText: "#FF0000"], appearance: .light)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: false, onEmphasizedSelection: false, highContrast: false) == .gridText)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: true, onEmphasizedSelection: false, highContrast: false) == .gridText)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: false, onEmphasizedSelection: true, highContrast: false) == nil)

            try ThemeTestFixture.adopt([.gridText: "#FF0000", .gridSelectionText: "#00AA00"], appearance: .light)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: true, onEmphasizedSelection: false, highContrast: false) == .gridSelectionText)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: false, onEmphasizedSelection: false, highContrast: false) == .gridText)
            #expect(ThemeTableChrome.recordsTextSlot(onThemedSelection: false, onEmphasizedSelection: true, highContrast: false) == nil)
        }
    }

    @Test("A records cell draws exactly its own text under the default theme")
    func defaultCellTextIsUntouched() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let cell = swatchCell(in: makeTable())
            #expect(matches(try center(cell.rootView), try center(plainSwatch)))

            cell.isOnThemedSelection = true
            #expect(matches(try center(cell.rootView), try center(plainSwatch)))
        }
    }

    @Test("A records cell takes the theme's grid text, and its selection text on the theme's selection")
    func cellTextFollowsTheTheme() throws {
        guard #available(macOS 14, *) else { return }
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt(ThemeTestFixture.pair([.gridText: "#FF0000", .gridSelection: "#C8E1FF", .gridSelectionText: "#00AA00"]), appearance: .light)
            let cell = swatchCell(in: makeTable())
            let red = try reference("#FF0000")
            let green = try reference("#00AA00")

            let unselected = try center(cell.rootView)
            #expect(matches(unselected, red), "drew \(unselected)")

            cell.isOnThemedSelection = true
            let selected = try center(cell.rootView)
            #expect(matches(selected, green), "drew \(selected)")

            cell.isOnThemedSelection = false
            #expect(matches(try center(cell.rootView), red))
        }
    }

    @Test("A secondary style inside a records cell stays a level of the theme's grid text")
    func secondaryTextFollowsTheThemeHue() throws {
        guard #available(macOS 14, *) else { return }
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt(ThemeTestFixture.pair([.gridText: "#FF0000"]), appearance: .light)
            let cell = ThemeTableChrome.HostingCell.make(
                Self.swatchID,
                in: makeTable().tableView,
                showing: Rectangle().fill(.secondary).frame(width: 8, height: 8)
            )
            let drawn = try center(cell.rootView)
            #expect(matches(drawn, try reference("#FF0000"), tolerance: 0.05), "drew \(drawn)")
            #expect(drawn.alphaComponent < 0.9, "drew \(drawn)")
        }
    }

    @Test("Without a selection text a theme's selection keeps the grid text")
    func themedSelectionWithoutSelectionTextKeepsGridText() throws {
        guard #available(macOS 14, *) else { return }
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt(ThemeTestFixture.pair([.gridText: "#FF0000", .gridSelection: "#C8E1FF"]), appearance: .light)
            let cell = swatchCell(in: makeTable())
            cell.isOnThemedSelection = true
            #expect(matches(try center(cell.rootView), try reference("#FF0000")))
        }
    }

    /// AppKit's emphasized selection is the accent color, which a theme's text is not chosen to sit on.
    @Test("On AppKit's emphasized selection a records cell keeps its own text, which flips with the row")
    func nativeEmphasizedSelectionKeepsTheFlip() throws {
        guard #available(macOS 14, *) else { return }
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt(ThemeTestFixture.pair([.gridText: "#FF0000", .gridSelectionText: "#00AA00"]), appearance: .light)
            let cell = swatchCell(in: makeTable())

            let flipped = try center(cell.rootView.environment(\.backgroundProminence, .increased))
            let native = try center(plainSwatch.environment(\.backgroundProminence, .increased))
            #expect(matches(flipped, native), "drew \(flipped), native \(native)")
            #expect(!matches(flipped, try reference("#FF0000")))
        }
    }

    @Test("A themed row tells its records cells when they sit on the theme's selection")
    func themedRowPublishesItsSelection() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.gridSelection: "#C8E1FF"], appearance: .light)
            let source = ChromeTableSource()
            source.vendsCells = true
            let table = makeTable(source: source)
            let chrome = attach(.records, to: table)
            defer { withExtendedLifetime(chrome) {} }

            table.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let row = try #require(table.tableView.rowView(atRow: 0, makeIfNecessary: true) as? ThemeTableRowView)
            row.isEmphasized = true
            let cell = try #require(table.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThemeTableChrome.HostingCell)
            let other = try #require(table.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ThemeTableChrome.HostingCell)
            #expect(cell.isOnThemedSelection)
            #expect(!other.isOnThemedSelection)

            row.isEmphasized = false
            #expect(!cell.isOnThemedSelection)

            row.isEmphasized = true
            table.tableView.deselectAll(nil)
            #expect(!cell.isOnThemedSelection)
        }
    }

    @Test("A records cell reused into AppKit's row view after the theme stops forgets the theme's selection")
    func reusedCellForgetsTheThemedSelection() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.gridSelection: "#C8E1FF"], appearance: .light)
            let source = ChromeTableSource()
            source.vendsCells = true
            let table = makeTable(source: source)
            let chrome = attach(.records, to: table)
            defer { withExtendedLifetime(chrome) {} }
            table.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let row = try #require(table.tableView.rowView(atRow: 0, makeIfNecessary: true) as? ThemeTableRowView)
            row.isEmphasized = true
            let themedCell = try #require(table.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThemeTableChrome.HostingCell)
            #expect(themedCell.isOnThemedSelection)

            try ThemeTestFixture.adopt([.gridText: "#FF0000", .gridSelectionText: "#00AA00"], appearance: .light)
            let nativeRow = try #require(table.tableView.rowView(atRow: 0, makeIfNecessary: true))
            nativeRow.isEmphasized = true
            #expect(type(of: nativeRow) == NSTableRowView.self)
            #expect(table.tableView.selectedRowIndexes == IndexSet(integer: 0))
            for row in 0 ..< table.tableView.numberOfRows {
                let cell = try #require(table.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ThemeTableChrome.HostingCell)
                #expect(!cell.isOnThemedSelection)
            }
            #expect(!themedCell.isOnThemedSelection)
        }
    }

    @Test("Under the default theme no records cell is told it sits on a theme's selection")
    func defaultRowsNeverMarkCells() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([:], appearance: .light)
            let source = ChromeTableSource()
            source.vendsCells = true
            let table = makeTable(source: source)
            let chrome = attach(.records, to: table)
            defer { withExtendedLifetime(chrome) {} }

            table.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let row = try #require(table.tableView.rowView(atRow: 0, makeIfNecessary: true))
            row.isEmphasized = true
            let cell = try #require(table.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThemeTableChrome.HostingCell)
            #expect(type(of: row) == NSTableRowView.self)
            #expect(!cell.isOnThemedSelection)
        }
    }
}
