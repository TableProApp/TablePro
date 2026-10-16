//
//  ThemeTableHeaderTests.swift
//  TableProTests
//
//  A records table (the query plan outline, the privilege tree) kept AppKit's header band over a
//  themed body, while the data grid's header took the theme. Its chrome now puts a themed header in
//  while the theme colors the grid's header, and hands the owner's own header back when it stops.
//

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
private final class FillHeaderSwatch: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

private final class SortIndicatorRecordingCell: NSTableHeaderCell {
    var drawnIndicators: [Bool] = []

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        drawnIndicators.append(ascending)
        super.drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: priority)
    }
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

    private func scope(_ overrides: [ThemeSlot: String]) throws -> ThemeScope {
        var theme = try ThemeTestFixture.theme(.light, overrides)
        theme.id = "test.records-header.\(UUID().uuidString)"
        return .fixed(theme)
    }

    /// The view's `draw(_:)` called straight into an sRGB bitmap, so the theme's hex reads back as
    /// written. Row 0 of the bitmap is the top of the view.
    private func raster(_ view: NSView) throws -> NSBitmapImageRep {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let cgContext = try #require(CGContext(
            data: nil,
            width: Int(view.bounds.width),
            height: Int(view.bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if view.isFlipped {
            cgContext.translateBy(x: 0, y: view.bounds.height)
            cgContext.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: view.isFlipped)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.draw(view.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: try #require(cgContext.makeImage()))
    }

    private func hex(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> String {
        ThemeColor(try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))).hex
    }

    /// Held to the expected color as a plain fill drawn the same way, so the conversion on the way
    /// into the bitmap cancels out.
    private func isNear(_ drawn: String, _ expected: String) -> Bool {
        guard let lhs = ThemeColor(hex: drawn), let color = ThemeColor(hex: expected)?.nsColor else { return false }
        let fill = FillHeaderSwatch(color: color)
        guard let rep = try? raster(fill), let reference = try? hex(rep, x: 1, y: 1),
              let rhs = ThemeColor(hex: reference) else { return false }
        return abs(Int(lhs.red) - Int(rhs.red)) <= 3
            && abs(Int(lhs.green) - Int(rhs.green)) <= 3
            && abs(Int(lhs.blue) - Int(rhs.blue)) <= 3
            && abs(Int(lhs.alpha) - Int(rhs.alpha)) <= 3
    }

    @Test("Under the default theme a records table keeps the header and corner its owner installed")
    func defaultThemeKeepsTheOwnersHeader() throws {
        let table = makeTable()
        let chrome = ThemeTableChrome(tableView: table.tableView, family: .records, scope: .fixed(BuiltInThemes.light))

        #expect(table.tableView.headerView === table.header)
        #expect(table.tableView.cornerView === table.corner)
        #expect(!chrome.isHeaderThemed)
        withExtendedLifetime(table.window) {}
    }

    @Test("A theme that colors the grid's header themes a records table's header, band and titles")
    func themedHeaderDrawsTheTheme() throws {
        let table = makeTable()
        let chrome = ThemeTableChrome(
            tableView: table.tableView,
            family: .records,
            scope: try scope([.gridHeaderBackground: "#21222C", .gridHeaderText: "#F8F8F2", .gridLine: "#44475A"])
        )
        let header = try #require(table.tableView.headerView as? ThemeTableHeaderView)
        #expect(chrome.isHeaderThemed)
        #expect(header.chrome === chrome)
        #expect(header !== table.header)
        #expect(table.tableView.cornerView is ThemeTableCornerView)

        let rep = try raster(header)
        let firstHeading = header.headerRect(ofColumn: 0)
        let band = try hex(rep, x: Int(firstHeading.maxX) - 12, y: 3)
        let past = try hex(rep, x: Int(header.bounds.maxX) - 4, y: 3)
        #expect(isNear(band, "#21222C"), "the band drew \(band)")
        #expect(isNear(past, "#21222C"), "past the last heading drew \(past)")

        var titleInk = 0
        for y in 0 ..< rep.pixelsHigh - 1 {
            for x in Int(firstHeading.minX) ..< Int(firstHeading.midX) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if ThemeColor(pixel).relativeLuminance > 0.5 { titleInk += 1 }
            }
        }
        #expect(titleInk > 0, "the title is not in the theme's light header text")
        withExtendedLifetime(table.window) {}
    }

    @Test("A themed header still draws the sort indicator of the primary sort column, and only that one")
    func themedHeaderDrawsTheSortIndicator() throws {
        let table = makeTable()
        let cells = table.tableView.tableColumns.map { column -> SortIndicatorRecordingCell in
            let cell = SortIndicatorRecordingCell(textCell: column.title)
            column.headerCell = cell
            column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            return cell
        }
        table.tableView.sortDescriptors = [
            NSSortDescriptor(key: "Cost", ascending: false),
            NSSortDescriptor(key: "Operation", ascending: true),
        ]
        let chrome = ThemeTableChrome(tableView: table.tableView, family: .records, scope: try scope([.gridHeaderBackground: "#21222C"]))
        let header = try #require(table.tableView.headerView as? ThemeTableHeaderView)

        _ = try raster(header)

        #expect(chrome.isHeaderThemed)
        #expect(cells[0].drawnIndicators.isEmpty)
        #expect(cells[1].drawnIndicators == [false])
        withExtendedLifetime(table.window) {}
    }

    @Test("A background-only theme heads a records table in that background, as the grid does")
    func backgroundOnlyThemeHeadsTheTable() throws {
        let table = makeTable()
        let chrome = ThemeTableChrome(tableView: table.tableView, family: .records, scope: try scope([.gridBackground: "#FDF6E3"]))
        let header = try #require(table.tableView.headerView as? ThemeTableHeaderView)

        #expect(chrome.isHeaderThemed)
        let past = try hex(raster(header), x: Int(header.bounds.maxX) - 4, y: 3)
        #expect(isNear(past, "#FDF6E3"), "drew \(past)")
        withExtendedLifetime(table.window) {}
    }

    @Test("A code table's header stays AppKit's, since the editor family has no header slots")
    func codeTablesKeepTheirHeader() throws {
        let table = makeTable()
        let chrome = ThemeTableChrome(tableView: table.tableView, family: .code, scope: try scope([.gridHeaderBackground: "#21222C"]))

        #expect(!chrome.isHeaderThemed)
        #expect(table.tableView.headerView === table.header)
        withExtendedLifetime(table.window) {}
    }

    @Test("When the theme stops coloring the header the owner's header and corner come back")
    func themeStopRestoresTheOwnersHeader() throws {
        try ThemeTestFixture.preservingEngine {
            try ThemeTestFixture.adopt([.gridHeaderBackground: "#21222C"], appearance: .light)
            let table = makeTable()
            let chrome = ThemeTableChrome(tableView: table.tableView, family: .records)
            #expect(table.tableView.headerView is ThemeTableHeaderView)

            ThemeTestFixture.adopt(.builtIn, appearance: .light)
            chrome.apply()

            #expect(!chrome.isHeaderThemed)
            #expect(table.tableView.headerView === table.header)
            #expect(table.tableView.cornerView === table.corner)
            withExtendedLifetime(table.window) {}
        }
    }
}
