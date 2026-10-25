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
private final class ScopedHeaderView: ThemeTableHeaderView {
    var scope: ThemeScope = .live

    override var themeScope: ThemeScope { scope }
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
    private func makeTable(
        header: NSTableHeaderView = NSTableHeaderView(),
        titles: [String] = ["Operation", "Cost"],
        themedCells: Bool = false
    ) -> Table {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        tableView.headerView = header
        for title in titles {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            if themedCells {
                column.headerCell = ThemeTableHeaderCell()
            }
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

    private static let headerTheme: [ThemeSlot: String] = [
        .gridHeaderBackground: "#21222C",
        .gridHeaderText: "#F8F8F2",
        .gridLine: "#44475A",
    ]

    private func scope(_ overrides: [ThemeSlot: String]) throws -> ThemeScope {
        .fixed(try ThemeTestFixture.theme(.light, overrides))
    }

    private func titleColor(_ cell: NSCell) -> NSColor? {
        let title = cell.attributedStringValue
        guard title.length > 0 else { return nil }
        return title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    private func titleFont(_ cell: NSCell) -> NSFont? {
        let title = cell.attributedStringValue
        guard title.length > 0 else { return nil }
        return title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    private func isBold(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.bold) == true
    }

    private func headerCells(of table: Table) -> [ThemeTableHeaderCell] {
        table.tableView.tableColumns.compactMap { $0.headerCell as? ThemeTableHeaderCell }
    }

    // MARK: - Chrome

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

    // MARK: - Cell geometry

    @Test("The interior is a 16 pt band centered in the header", arguments: [CGFloat(22), 28, 34])
    func interiorIsCentered(height: CGFloat) {
        let frame = NSRect(x: 10, y: 0, width: 120, height: height)

        #expect(ThemeTableHeaderCell.interiorRect(in: frame) == NSRect(x: 10, y: (height - 16) / 2, width: 120, height: 16))
    }

    @Test("A header shorter than the band gets an interior its own height")
    func interiorNeverOverflows() {
        let frame = NSRect(x: 10, y: 0, width: 120, height: 12)

        #expect(ThemeTableHeaderCell.interiorRect(in: frame) == frame)
    }

    @Test("The bottom line is 1 pt along the cell's bottom edge, full width")
    func bottomLineSitsOnTheBottomEdge() {
        let frame = NSRect(x: 10, y: 0, width: 120, height: 28)

        #expect(ThemeTableHeaderCell.bottomLineRect(in: frame) == NSRect(x: 10, y: 27, width: 120, height: 1))
    }

    @Test("The divider is 1 pt at the cell's trailing edge and spans only the band")
    func dividerSpansTheBand() {
        let frame = NSRect(x: 10, y: 0, width: 120, height: 28)
        let interior = ThemeTableHeaderCell.interiorRect(in: frame)

        #expect(ThemeTableHeaderCell.dividerRect(in: frame, interior: interior) == NSRect(x: 129, y: 6, width: 1, height: 16))
    }

    @Test("Only the band past the last column is a filler")
    func fillerStartsPastTheLastColumn() throws {
        let table = makeTable(themedCells: true)
        let last = table.tableView.rect(ofColumn: table.tableView.numberOfColumns - 1)
        let first = table.tableView.rect(ofColumn: 0)

        #expect(!ThemeTableHeaderCell.isFiller(NSRect(x: first.minX, y: 0, width: first.width, height: 28), of: table.tableView))
        #expect(!ThemeTableHeaderCell.isFiller(NSRect(x: last.minX, y: 0, width: last.width, height: 28), of: table.tableView))
        #expect(ThemeTableHeaderCell.isFiller(NSRect(x: last.maxX, y: 0, width: 40, height: 28), of: table.tableView))

        let empty = makeTable(titles: [])
        #expect(ThemeTableHeaderCell.isFiller(NSRect(x: 0, y: 0, width: 40, height: 28), of: empty.tableView))
        withExtendedLifetime(table.window) {}
        withExtendedLifetime(empty.window) {}
    }

    // MARK: - Title

    @Test("Styling a title colors it, bolds it only when asked, and drops the bold again")
    func styleTitleSetsColorAndWeight() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let cell = ThemeTableHeaderCell()
        cell.stringValue = "Cost"

        cell.styleTitle(color: red, bold: false)
        #expect(cell.attributedStringValue.string == "Cost")
        #expect(titleColor(cell) == red)
        #expect(!isBold(titleFont(cell)))

        cell.styleTitle(color: red, bold: true)
        #expect(titleColor(cell) == red)
        #expect(isBold(titleFont(cell)))

        cell.styleTitle(color: blue, bold: false)
        #expect(titleColor(cell) == blue)
        #expect(!isBold(titleFont(cell)))
    }

    // The header restyles before every draw, so a title already styled must not be written again.
    @Test("Styling a title already in its color and weight leaves it as it is")
    func styleTitleSkipsAStyledTitle() throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let cell = ThemeTableHeaderCell()
        cell.stringValue = "Cost"
        cell.styleTitle(color: red, bold: false)
        let font = try #require(titleFont(cell))

        let mixed = NSMutableAttributedString(string: "Cost", attributes: [.foregroundColor: red, .font: font])
        mixed.addAttribute(.foregroundColor, value: green, range: NSRange(location: 2, length: 2))
        cell.attributedStringValue = mixed

        cell.styleTitle(color: red, bold: false)
        #expect(cell.attributedStringValue.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == green)

        cell.styleTitle(color: red, bold: true)
        #expect(cell.attributedStringValue.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == red)
    }

    @Test("Styling an empty title leaves it empty")
    func styleTitleIgnoresAnEmptyTitle() {
        let cell = ThemeTableHeaderCell()
        cell.stringValue = ""

        cell.styleTitle(color: .systemRed, bold: true)

        #expect(cell.attributedStringValue.length == 0)
    }

    @Test("Before a draw the header styles its theme cells in the scope's header text, the highlighted column bold")
    func viewWillDrawStylesTheTitles() throws {
        let header = ScopedHeaderView()
        header.scope = try scope(Self.headerTheme)
        let table = makeTable(header: header, themedCells: true)
        let plain = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Plain"))
        plain.title = "Plain"
        table.tableView.addTableColumn(plain)
        let cells = headerCells(of: table)
        #expect(cells.count == 2)

        header.viewWillDraw()
        for cell in cells {
            #expect(ThemeTestFixture.hex(titleColor(cell)) == "#F8F8F2")
            #expect(!isBold(titleFont(cell)))
        }
        #expect(ThemeTestFixture.hex(titleColor(plain.headerCell)) != "#F8F8F2")

        table.tableView.highlightedTableColumn = table.tableView.tableColumns[1]
        header.viewWillDraw()
        #expect(!isBold(titleFont(cells[0])))
        #expect(isBold(titleFont(cells[1])))
        #expect(ThemeTestFixture.hex(titleColor(cells[1])) == "#F8F8F2")

        table.tableView.highlightedTableColumn = nil
        header.viewWillDraw()
        #expect(!isBold(titleFont(cells[1])))
        withExtendedLifetime(table.window) {}
    }

    @Test("With the header text unset the titles take the system header text color")
    func unsetHeaderTextIsTheSystemColor() throws {
        let header = ScopedHeaderView()
        header.scope = .fixed(BuiltInThemes.light)
        let table = makeTable(header: header, themedCells: true)

        header.viewWillDraw()

        #expect(ThemeTableHeaderView().themeScope === ThemeScope.live)
        for cell in headerCells(of: table) {
            #expect(titleColor(cell) == NSColor.headerTextColor)
        }
        withExtendedLifetime(table.window) {}
    }

    // MARK: - Drawing

    // Drawn straight into an sRGB bitmap, flipped like the header, so row 0 of the bitmap is the top.
    private func raster(size: NSSize, _ draw: () -> Void) throws -> NSBitmapImageRep {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let aqua = try #require(NSAppearance(named: .aqua))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        aqua.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    // A plain fill through the same bitmap, so the conversion on the way in cancels out.
    private func reference(_ color: NSColor) throws -> NSColor {
        let rep = try raster(size: NSSize(width: 4, height: 4)) {
            color.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        }
        return try #require(ThemeTestFixture.pixel(rep, x: 1, y: 1))
    }

    private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> NSColor {
        try #require(ThemeTestFixture.pixel(rep, x: Int(x), y: Int(y)))
    }

    private struct DrawnHeader {
        let rep: NSBitmapImageRep
        let cellFrame: NSRect
        let fillerFrame: NSRect
        let interior: NSRect
    }

    private func drawHeader(scope: ThemeScope) throws -> DrawnHeader {
        let header = ScopedHeaderView()
        header.scope = scope
        let table = makeTable(header: header, themedCells: true)
        defer { withExtendedLifetime(table.window) {} }
        header.viewWillDraw()
        let height: CGFloat = 28
        let first = table.tableView.rect(ofColumn: 0)
        let last = table.tableView.rect(ofColumn: table.tableView.numberOfColumns - 1)
        let cellFrame = NSRect(x: first.minX, y: 0, width: first.width, height: height)
        let fillerFrame = NSRect(x: last.maxX, y: 0, width: 40, height: height)
        let cell = try #require(headerCells(of: table).first)
        let filler = ThemeTableHeaderCell()
        let rep = try raster(size: NSSize(width: fillerFrame.maxX, height: height)) {
            cell.draw(withFrame: cellFrame, in: header)
            filler.draw(withFrame: fillerFrame, in: header)
        }
        return DrawnHeader(
            rep: rep,
            cellFrame: cellFrame,
            fillerFrame: fillerFrame,
            interior: ThemeTableHeaderCell.interiorRect(in: cellFrame)
        )
    }

    @Test("A theme cell paints the band, the bottom line and the divider in the theme, with no divider past the last column")
    func cellPaintsTheTheme() throws {
        let drawn = try drawHeader(scope: try scope(Self.headerTheme))
        let band = try reference(HexColor.color("#21222C"))
        let line = try reference(HexColor.color("#44475A"))
        let frame = drawn.cellFrame
        let filler = drawn.fillerFrame

        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: frame.minX + 2, y: 1), band))
        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: frame.minX + 2, y: frame.maxY - 1), line))
        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: frame.maxX - 1, y: drawn.interior.midY), line))
        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: frame.maxX - 1, y: 1), band))
        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: filler.maxX - 1, y: 1), band))
        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: filler.maxX - 1, y: drawn.interior.midY), band))
        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: filler.maxX - 1, y: filler.maxY - 1), line))

        var titleInk = 0
        for y in Int(drawn.interior.minY) ..< Int(drawn.interior.maxY) {
            for x in Int(frame.minX) ..< Int(frame.midX) {
                guard let color = ThemeTestFixture.pixel(drawn.rep, x: x, y: y) else { continue }
                if ThemeColor(color).relativeLuminance > 0.5 { titleInk += 1 }
            }
        }
        #expect(titleInk > 0, "the title is not in the theme's light header text")
    }

    @Test("With the header background unset the band is the system's control background")
    func unsetBandIsTheSystemColor() throws {
        let drawn = try drawHeader(scope: .fixed(BuiltInThemes.light))
        let band = try reference(.controlBackgroundColor)

        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: drawn.cellFrame.minX + 2, y: 1), band))
        #expect(ThemeTestFixture.matches(try pixel(drawn.rep, x: drawn.fillerFrame.maxX - 1, y: 1), band))
    }
}
