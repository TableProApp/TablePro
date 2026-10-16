//
//  DataGridThemeScopeTests.swift
//  TableProTests
//
//  A grid draws every color through the scope it is handed, so the theme editor can show a draft in
//  a real grid while every other grid keeps the app's theme. Mounted through `DataGridView` itself,
//  the way the editor's preview mounts it, and rasterized into sRGB so a theme's hex reads back as
//  written. Every case runs on fixed scopes and leaves the shared engine alone.
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTheme
import Testing

@MainActor
private final class ScopeLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class ScopedGrid {
    private let window: NSWindow
    private let host: NSHostingView<DataGridView>
    private let rows: TableRows

    init(scope: ThemeScope, appearance: NSAppearance.Name = .aqua, rowCount: Int = 4) async {
        let columns = ["id", "name"]
        rows = TableRows.from(
            queryRows: (0 ..< rowCount).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } },
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        host = NSHostingView(rootView: Self.makeGrid(rows: rows, scope: scope))
        window.contentView = host
        await settle()
        tableView?.usesAlternatingRowBackgroundColors = true
    }

    /// A new root value, which is how the editor hands the preview a new draft.
    func show(scope: ThemeScope) async {
        host.rootView = Self.makeGrid(rows: rows, scope: scope)
        await settle()
    }

    func close() {
        window.orderOut(nil)
    }

    var tableView: KeyHandlingTableView? {
        Self.first(KeyHandlingTableView.self, in: host)
    }

    var coordinator: TableViewCoordinator? { tableView?.coordinator }

    var header: SortableHeaderView? { tableView?.headerView as? SortableHeaderView }

    func rowView(_ row: Int) throws -> DataGridRowView {
        let tableView = try #require(tableView)
        return try #require(tableView.rowView(atRow: row, makeIfNecessary: true) as? DataGridRowView)
    }

    private static func makeGrid(rows: TableRows, scope: ThemeScope) -> DataGridView {
        DataGridView(
            tableRowsProvider: { rows },
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            configuration: DataGridConfiguration(tabType: .query),
            layoutPersister: ScopeLayoutPersister(),
            selectedRowIndices: .constant([]),
            sortState: .constant(SortState()),
            columnLayout: .constant(ColumnLayoutState()),
            themeScope: scope
        )
    }

    private func settle() async {
        for _ in 0 ..< 10 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }
}

/// A view's drawing methods called straight into an sRGB bitmap, the way AppKit calls them, so a
/// theme's hex reads back as written. `cacheDisplay` of a table and its rows goes through the layer
/// tree and the window's color space instead.
@MainActor
private struct Raster {
    let rep: NSBitmapImageRep
    let bounds: NSRect
    let isFlipped: Bool

    init(_ view: NSView, draw: (NSRect) -> Void) throws {
        let area = view.bounds
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let cgContext = try #require(CGContext(
            data: nil,
            width: Int(area.width),
            height: Int(area.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if view.isFlipped {
            cgContext.translateBy(x: 0, y: area.height)
            cgContext.scaleBy(x: 1, y: -1)
        }
        cgContext.translateBy(x: -area.minX, y: -area.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: view.isFlipped)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            draw(area)
        }
        NSGraphicsContext.restoreGraphicsState()
        rep = NSBitmapImageRep(cgImage: try #require(cgContext.makeImage()))
        bounds = area
        isFlipped = view.isFlipped
    }

    /// What a row view lays down, in AppKit's order: background, selection, then the cells.
    static func row(_ rowView: DataGridRowView) throws -> Raster {
        try Raster(rowView) { rect in
            rowView.drawBackground(in: rect)
            if rowView.isSelected {
                rowView.drawSelection(in: rect)
            }
            rowView.drawCells(in: rect, of: rowView)
        }
    }

    static func view(_ view: NSView) throws -> Raster {
        try Raster(view) { view.draw($0) }
    }

    func color(at point: NSPoint) throws -> NSColor {
        let column = Int(point.x - bounds.minX)
        let fromTop = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        return try #require(rep.colorAt(x: column, y: Int(fromTop))?.usingColorSpace(.sRGB))
    }

    func hex(at point: NSPoint) throws -> String {
        ThemeColor(try color(at: point)).hex
    }

    /// The lightest and darkest pixels in `rect`, by relative luminance.
    func luminanceRange(in rect: NSRect) throws -> ClosedRange<Double> {
        var lowest = Double.infinity
        var highest = -Double.infinity
        for y in Int(rect.minY) ..< Int(rect.maxY) {
            for x in Int(rect.minX) ..< Int(rect.maxX) {
                let luminance = ThemeColor(try color(at: NSPoint(x: x, y: y))).relativeLuminance
                lowest = min(lowest, luminance)
                highest = max(highest, luminance)
            }
        }
        return lowest ... highest
    }
}

/// Held to the expected color drawn the same way, a plain fill through the same context, so the
/// conversion AppKit applies on the way into the bitmap cancels out. Within three levels a channel.
@MainActor
private func isNear(_ drawn: String, _ expected: String) -> Bool {
    guard let lhs = ThemeColor(hex: drawn),
          let color = ThemeColor(hex: expected)?.nsColor,
          let reference = try? Raster(NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2)), draw: { rect in
              color.setFill()
              rect.fill()
          }).hex(at: NSPoint(x: 1, y: 1)),
          let rhs = ThemeColor(hex: reference) else { return false }
    return abs(Int(lhs.red) - Int(rhs.red)) <= 3
        && abs(Int(lhs.green) - Int(rhs.green)) <= 3
        && abs(Int(lhs.blue) - Int(rhs.blue)) <= 3
        && abs(Int(lhs.alpha) - Int(rhs.alpha)) <= 3
}

@MainActor
struct DataGridThemeScopeTests {
    private func scope(_ appearance: ThemeAppearance, _ overrides: [ThemeSlot: String]) throws -> ThemeScope {
        var theme = try ThemeTestFixture.theme(appearance, overrides)
        theme.id = "test.grid-scope.\(UUID().uuidString)"
        return .fixed(theme)
    }

    private func rgb(_ color: CGColor) -> String? {
        ThemeTestFixture.hex(color).map { String($0.prefix(7)) }
    }

    /// Clear of every cell's text: the width past the last column, which the row still paints.
    private func backgroundPoint(of rowView: NSView) -> NSPoint {
        NSPoint(x: rowView.bounds.maxX - 6, y: rowView.bounds.midY)
    }

    // MARK: - The scope reaches every surface

    @Test("A grid on a fixed scope draws that theme on its table, rows, cells, header and overlays")
    func fixedScopeReachesEverySurface() async throws {
        try #require(!ThemeScope.live.resolved.isOverridden(.gridBackground), "the app's theme colors the grid")
        let scope = try scope(.light, [
            .gridBackground: "#FDF6E3",
            .gridText: "#112233",
            .gridLine: "#AA0000",
            .gridHeaderText: "#00AA00",
        ])
        let grid = await ScopedGrid(scope: scope)
        defer { grid.close() }
        let tableView = try #require(grid.tableView)
        let coordinator = try #require(grid.coordinator)
        let header = try #require(grid.header)

        #expect(coordinator.themeScope === scope)
        #expect(tableView.themeScope === scope)
        #expect(header.themeScope === scope)
        #expect(CellOverlayBase.themeScope(of: tableView) === scope)
        #expect(ThemeTestFixture.hex(tableView.backgroundColor) == "#FDF6E3")
        #expect(ThemeTestFixture.hex(tableView.gridColor) == "#AA0000")
        #expect(ThemeTestFixture.hex(coordinator.cellRegistry.palette.text) == "#112233")
        #expect(ThemeTestFixture.hex(SortableHeaderChrome.backgroundColor(scope: header.themeScope)) == "#FDF6E3")
        #expect(!ThemeScope.live.resolved.isOverridden(.gridBackground), "the scope leaked into the app's theme")

        let even = try grid.rowView(0)
        let odd = try grid.rowView(1)
        let evenFill = try Raster.row(even).hex(at: backgroundPoint(of: even))
        let oddFill = try Raster.row(odd).hex(at: backgroundPoint(of: odd))
        #expect(isNear(evenFill, "#FDF6E3"), "drew \(evenFill)")
        #expect(isNear(oddFill, "#F3ECDA"), "a background-only theme stripes from its background, drew \(oddFill)")
    }

    @Test("A grid on the app's theme keeps the system's own colors")
    func liveScopeIsNative() async throws {
        try #require(!ThemeScope.live.resolved.isOverridden(.gridBackground), "the app's theme colors the grid")
        let grid = await ScopedGrid(scope: .live)
        defer { grid.close() }
        let tableView = try #require(grid.tableView)
        let coordinator = try #require(grid.coordinator)

        #expect(coordinator.themeScope === ThemeScope.live)
        #expect(tableView.backgroundColor == NSColor.controlBackgroundColor)
        #expect(coordinator.cellRegistry.palette.text == NSColor.labelColor)
    }

    @Test("A new scope repaints the grid in place, keeping its coordinator, row views and formatted values")
    func newScopeRepaintsInPlace() async throws {
        let first = try scope(.light, [.gridBackground: "#FDF6E3", .gridText: "#112233"])
        let second = try scope(.light, [.gridBackground: "#E6E7ED", .gridText: "#343B59"])
        let grid = await ScopedGrid(scope: first)
        defer { grid.close() }
        let tableView = try #require(grid.tableView)
        let coordinator = try #require(grid.coordinator)
        let rowView = try grid.rowView(0)
        let displayCache = coordinator.displayCache

        await grid.show(scope: second)

        #expect(grid.coordinator === coordinator)
        #expect(coordinator.themeScope === second)
        #expect(ThemeTestFixture.hex(tableView.backgroundColor) == "#E6E7ED")
        #expect(ThemeTestFixture.hex(coordinator.cellRegistry.palette.text) == "#343B59")
        #expect(tableView.rowView(atRow: 0, makeIfNecessary: false) === rowView, "the rows were rebuilt")
        #expect(coordinator.displayCache === displayCache)
        let fill = try Raster.row(rowView).hex(at: backgroundPoint(of: rowView))
        #expect(isNear(fill, "#E6E7ED"), "drew \(fill)")

        await grid.show(scope: .live)

        #expect(coordinator.themeScope === ThemeScope.live)
        #expect(tableView.backgroundColor == NSColor.controlBackgroundColor)
        #expect(coordinator.cellRegistry.palette.text == NSColor.labelColor)
    }

    // MARK: - Derived slots, end to end

    @Test("A background-only light theme stripes the rows, the gutter and the header from its own background")
    func backgroundOnlyLightStripes() async throws {
        try await assertBackgroundOnlyStripes(appearance: .light, name: .aqua, background: "#FDF6E3", stripe: "#F3ECDA")
    }

    @Test("A background-only dark theme stripes the rows, the gutter and the header toward white")
    func backgroundOnlyDarkStripes() async throws {
        try await assertBackgroundOnlyStripes(appearance: .dark, name: .darkAqua, background: "#282A36", stripe: "#31333E")
    }

    private func assertBackgroundOnlyStripes(
        appearance: ThemeAppearance,
        name: NSAppearance.Name,
        background: String,
        stripe: String
    ) async throws {
        let grid = await ScopedGrid(scope: try scope(appearance, [.gridBackground: background]), appearance: name)
        defer { grid.close() }
        let tableView = try #require(grid.tableView)
        let gutter = try #require(grid.coordinator?.rowGutter)
        let header = try #require(grid.header)
        let even = try grid.rowView(2)
        let odd = try grid.rowView(3)

        let evenFill = try Raster.row(even).hex(at: backgroundPoint(of: even))
        let oddFill = try Raster.row(odd).hex(at: backgroundPoint(of: odd))
        #expect(isNear(evenFill, background), "drew \(evenFill)")
        #expect(isNear(oddFill, stripe), "drew \(oddFill)")

        let oddBand = gutter.convert(tableView.rect(ofRow: 3), from: tableView)
        let gutterFill = try Raster.view(gutter).hex(at: NSPoint(x: 2, y: oddBand.midY))
        #expect(isNear(gutterFill, stripe), "the gutter drew \(gutterFill)")

        #expect(ThemeTestFixture.hex(SortableHeaderChrome.backgroundColor(scope: header.themeScope), in: name) == background)
    }

    // MARK: - Header

    /// `NSTableHeaderView.draw` lays AppKit's own band over whatever is beneath it, so a header that
    /// filled the theme's color and then let AppKit draw showed AppKit's band.
    @Test("A theme's header background is what the grid's header shows, behind and between the headings")
    func themedHeaderBandShows() async throws {
        let grid = await ScopedGrid(
            scope: try scope(.dark, [.gridHeaderBackground: "#21222C", .gridHeaderText: "#F8F8F2"]),
            appearance: .darkAqua
        )
        defer { grid.close() }
        let coordinator = try #require(grid.coordinator)
        let header = try #require(grid.header)
        let column = try #require(coordinator.tableColumnIndex(forDisplayPosition: 1))
        let heading = header.headerRect(ofColumn: column)
        let raster = try Raster.view(header)
        let behind = try raster.hex(at: NSPoint(x: heading.minX + 3, y: heading.minY + 3))
        let past = try raster.hex(at: NSPoint(x: header.bounds.maxX - 4, y: header.bounds.minY + 3))

        #expect(isNear(behind, "#21222C"), "behind a heading drew \(behind)")
        #expect(isNear(past, "#21222C"), "past the headings drew \(past)")
    }

    // MARK: - Selection text, end to end

    /// The rows' text is the dark ink of the theme's text, never AppKit's white selection text.
    @Test("A theme that sets the selection but not its text draws the theme's text on the selection")
    func selectionWithoutTextTakesTheGridText() async throws {
        let grid = await ScopedGrid(scope: try scope(.light, [.gridSelection: "#EEE8D5", .gridText: "#112233"]))
        defer { grid.close() }
        let tableView = try #require(grid.tableView)
        let coordinator = try #require(grid.coordinator)
        let header = try #require(grid.header)
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let rowView = try grid.rowView(1)
        rowView.isEmphasized = true

        let cell = try #require(coordinator.cellAppearance(row: 1, columnIndex: 0, onEmphasizedSelection: true))
        #expect(ThemeTestFixture.hex(cell.textColor) == "#112233")
        #expect(ThemeTestFixture.hex(coordinator.cellRegistry.palette.rowNumberColor(for: .empty, onEmphasizedSelection: true)) == "#112233")
        let heading = SortableHeaderCell(textCell: "name")
        #expect(ThemeTestFixture.hex(heading.foregroundColor(emphasized: true, scope: header.themeScope)) == "#112233")

        let raster = try Raster.row(rowView)
        let fill = try raster.hex(at: backgroundPoint(of: rowView))
        #expect(isNear(fill, "#EEE8D5"), "drew \(fill)")
        let selectionLuminance = try #require(ThemeColor(hex: fill)).relativeLuminance
        let firstCell = rowView.convert(tableView.rect(ofColumn: try #require(coordinator.tableColumnIndex(forDisplayPosition: 0))), from: tableView)
        let range = try raster.luminanceRange(in: firstCell.intersection(rowView.bounds).insetBy(dx: 2, dy: 2))
        #expect(range.upperBound <= selectionLuminance + 0.03, "a pixel lighter than the selection is white text: \(range)")
        #expect(range.lowerBound < 0.2, "the cell drew no dark text: \(range)")
    }

    @Test("A selection text with no themed selection leaves AppKit's own selection and its white text")
    func selectionTextAloneStaysNative() async throws {
        let grid = await ScopedGrid(scope: try scope(.light, [.gridSelectionText: "#00FF00", .gridText: "#112233"]))
        defer { grid.close() }
        let coordinator = try #require(grid.coordinator)

        let cell = try #require(coordinator.cellAppearance(row: 0, columnIndex: 0, onEmphasizedSelection: true))
        #expect(cell.textColor === NSColor.alternateSelectedControlTextColor)
        #expect(DataGridBodyChrome.themedSelectionColor(emphasized: true, scope: coordinator.themeScope) == nil)
    }

    // MARK: - Translucent selection

    /// The row used to replace its stripe with the translucent color, the heading replaced the
    /// header's band, and the gutter blended over the stripe: three colors for one selection.
    @Test("A translucent selection draws one color on the row, the gutter and a selected heading")
    func translucentSelectionAgrees() async throws {
        let scope = try scope(.dark, [
            .gridBackground: "#282A36",
            .gridAlternateRow: "#21222C",
            .gridHeaderBackground: "#21222C",
            .gridInactiveSelection: "#44475A80",
        ])
        let selection = try #require(ThemeColor(hex: "#44475A80"))
        let expected = selection.composited(over: try #require(ThemeColor(hex: "#282A36"))).hex
        let grid = await ScopedGrid(scope: scope, appearance: .darkAqua)
        defer { grid.close() }
        let tableView = try #require(grid.tableView)
        let coordinator = try #require(grid.coordinator)
        let gutter = try #require(coordinator.rowGutter)
        let header = try #require(grid.header)
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let rowView = try grid.rowView(1)
        rowView.isEmphasized = false

        let fill = try #require(DataGridBodyChrome.themedSelectionColor(emphasized: false, scope: scope))
        #expect(ThemeTestFixture.hex(fill, in: .darkAqua) == expected)
        #expect(fill.alphaComponent == 1)

        let row = try Raster.row(rowView).hex(at: backgroundPoint(of: rowView))
        #expect(isNear(row, expected), "the row drew \(row), expected \(expected)")

        let band = gutter.convert(tableView.rect(ofRow: 1), from: tableView)
        let strip = try Raster.view(gutter).hex(at: NSPoint(x: 2, y: band.midY))
        #expect(isNear(strip, expected), "the gutter drew \(strip), expected \(expected)")

        let column = try #require(coordinator.tableColumnIndex(forDisplayPosition: 0))
        let cell = try #require(tableView.tableColumns[column].headerCell as? SortableHeaderCell)
        cell.isColumnSelected = true
        cell.isEmphasized = false
        defer { cell.isColumnSelected = false }
        let heading = header.headerRect(ofColumn: column)
        let headingFill = try Raster.view(header).hex(at: NSPoint(x: heading.minX + 3, y: heading.minY + 3))
        #expect(isNear(headingFill, expected), "the heading drew \(headingFill), expected \(expected)")
    }

    // MARK: - Range outline

    @Test("Under the default theme a cell range keeps the selection at 70% as its outline")
    func defaultRangeBorderIsNative() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let resolved = ThemeScope.fixed(BuiltInThemes.light).resolved
        let drawn = ThemeTestFixture.baked(GridSelectionOverlay.rangeBorderColor(resolved), in: aqua)
        let native = ThemeTestFixture.resolved(in: aqua) {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.7).cgColor
        }

        #expect(ThemeTestFixture.hex(drawn) == ThemeTestFixture.hex(native))
        #expect(abs(drawn.alpha - 0.7) < 0.001)
    }

    /// The theme's selection fills the range opaque, so the selection itself at 70% drew no edge.
    @Test("Under a theme's selection the range outline is the active cell's border and stands apart from the fill")
    func themedRangeBorderStandsApart() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let withFocus = try scope(.dark, [.gridSelection: "#44475A", .gridFocusBorder: "#BD93F9"]).resolved
        let border = ThemeTestFixture.baked(GridSelectionOverlay.rangeBorderColor(withFocus), in: aqua)
        #expect(rgb(border) == "#BD93F9")
        #expect(abs(border.alpha - 0.7) < 0.001)

        let fill = try #require(ThemeColor(hex: "#44475A"))
        let stroke = try #require(ThemeColor(hex: "#BD93F9B3")).composited(over: fill)
        #expect(stroke.contrastRatio(with: fill) > 2)

        let withoutFocus = try scope(.dark, [.gridSelection: "#44475A"]).resolved
        let accent = ThemeTestFixture.baked(GridSelectionOverlay.rangeBorderColor(withoutFocus), in: aqua)
        #expect(rgb(accent) == rgb(ThemeTestFixture.baked(.controlAccentColor, in: aqua)))
    }

    // MARK: - Accessory glyphs

    @Test("An accessory glyph is drawn again for another color, and reused for the same one")
    func accessoryGlyphFollowsItsColor() throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        let first = try #require(DataGridCellAccessoryGlyph.image(for: .foreignKeyEmphasized, color: red))
        let again = try #require(DataGridCellAccessoryGlyph.image(for: .foreignKeyEmphasized, color: red))
        let other = try #require(DataGridCellAccessoryGlyph.image(for: .foreignKeyEmphasized, color: blue))

        #expect(first.image === again.image)
        #expect(other.image !== first.image)
    }

    @Test("An emphasized accessory takes the paired selection text, a plain one the secondary label")
    func accessoryColorFollowsTheSelectionPair() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let scope = try scope(.light, [.gridSelection: "#EEE8D5", .gridText: "#112233"])
        let palette = scope.dataGridCellPalette(in: aqua)
        func appearance(emphasized: Bool) -> DataGridCellAppearance {
            DataGridCellAppearance.resolve(
                kind: .foreignKey,
                content: DataGridCellContent(displayText: "7", rawValue: "7", placeholder: nil),
                state: DataGridCellState(
                    visualState: .empty,
                    isFocused: false,
                    isEditable: true,
                    isLargeDataset: false,
                    isCurrentFindMatch: false,
                    row: 0,
                    columnIndex: 0
                ),
                palette: palette,
                nullDisplayString: "NULL",
                onEmphasizedSelection: emphasized,
                hasOverlay: false
            )
        }

        #expect(ThemeTestFixture.hex(appearance(emphasized: true).accessoryColor) == "#112233")
        #expect(appearance(emphasized: false).accessoryColor === NSColor.secondaryLabelColor)
    }
}
