//
//  DataGridThemeDrawingTests.swift
//  TableProTests
//
//  Default Light and Default Dark declare no grid color, so the grid has to draw what AppKit draws:
//  NSTableRowView's own selection, `headerTextColor`, `separatorColor`. A theme that declares a
//  grid color has to reach every surface that shows it, the row-number gutter included.
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class ThemeDrawingLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// Overriding a draw method moves a row off AppKit's update-layer path, so this takes the same path
/// as `DataGridRowView` and the two can be held pixel for pixel to each other.
@MainActor
private final class DrawPathRowView: NSTableRowView {
    // swiftlint:disable:next unneeded_override
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
    }
}

/// Each test adopts a pair on the shared `ThemeEngine` and restores it in a `defer`. The bodies are
/// synchronous and `@MainActor`, so nothing else on the main actor runs between the two; an `await`
/// added anywhere in between would break that.
@Suite("Data grid drawing follows the theme", .serialized)
@MainActor
struct DataGridThemeDrawingTests {
    private static let rowFrame = NSRect(x: 0, y: 0, width: 160, height: 24)

    private struct Grid {
        let window: NSWindow
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator
    }

    private func adopting(_ overrides: [ThemeSlot: String], _ body: () throws -> Void) throws {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }

        var theme = BuiltInThemes.light
        if !overrides.isEmpty {
            theme.id = "test.grid-theme-drawing"
            for (slot, hex) in overrides {
                theme.overrides[slot] = try ThemeColor(validating: hex)
            }
        }
        engine.adopt(ThemeSelection(
            pair: ThemePair(light: theme, dark: BuiltInThemes.dark),
            effectiveAppearance: .light
        ))
        try body()
    }

    private func selected(_ row: NSTableRowView, emphasized: Bool) throws -> NSTableRowView {
        row.appearance = try #require(NSAppearance(named: .aqua))
        row.wantsLayer = true
        row.isSelected = true
        row.isEmphasized = emphasized
        return row
    }

    private func centerColor(of view: NSView) throws -> NSColor {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private func matches(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    private func cellAppearance(palette: DataGridCellPalette, onEmphasizedSelection: Bool) -> DataGridCellAppearance {
        DataGridCellAppearance.resolve(
            kind: .text,
            content: DataGridCellContent(displayText: "value", rawValue: "value", placeholder: nil),
            state: DataGridCellState(
                visualState: .empty,
                isFocused: true,
                isEditable: true,
                isLargeDataset: false,
                isCurrentFindMatch: false,
                row: 0,
                columnIndex: 0
            ),
            palette: palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: onEmphasizedSelection,
            hasOverlay: false
        )
    }

    private func makeGrid(rows: Int = 3) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: ThemeDrawingLayoutPersister()
        )
        let columns = ["id", "name"]
        let columnTypes = Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        let tableRows = TableRows.from(
            queryRows: (0..<rows).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } },
            columns: columns,
            columnTypes: columnTypes
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 21
        tableView.allowsMultipleSelection = true
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 120 }
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        for row in 0..<rows {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
        }
        return Grid(window: window, tableView: tableView, coordinator: coordinator)
    }

    // MARK: - Row selection

    /// The regression this guards: the row painted the accent at 28% under white text, 1.5:1 in
    /// Light. Without a theme selection the row is `NSTableRowView`'s own drawing, so it is held to a
    /// stock row in the same state, whatever AppKit draws there.
    @Test("Under the default theme a selected row draws exactly what NSTableRowView draws", arguments: [true, false])
    func defaultThemeSelectionIsNative(emphasized: Bool) throws {
        try adopting([:]) {
            #expect(DataGridBodyChrome.themedSelectionColor(emphasized: emphasized) == nil)

            let grid = try centerColor(of: selected(DataGridRowView(frame: Self.rowFrame), emphasized: emphasized))
            let stock = try centerColor(of: selected(DrawPathRowView(frame: Self.rowFrame), emphasized: emphasized))
            #expect(matches(grid, stock), "grid row \(grid), stock row \(stock)")
        }
    }

    @Test("Under the default theme the gutter and a selected heading fill with the system selection")
    func defaultThemeSelectionColors() throws {
        try adopting([:]) {
            #expect(DataGridBodyChrome.selectionColor(emphasized: true) == .selectedContentBackgroundColor)
            #expect(DataGridBodyChrome.selectionColor(emphasized: false) == .unemphasizedSelectedContentBackgroundColor)

            let aqua = try #require(NSAppearance(named: .aqua))
            let palette = ThemeEngine.shared.dataGridCellPalette(in: aqua)
            #expect(palette.selectionText == .alternateSelectedControlTextColor)
            #expect(palette.rowNumberColor(for: .empty, onEmphasizedSelection: true) == .alternateSelectedControlTextColor)
            #expect(palette.rowNumberColor(for: .empty, onEmphasizedSelection: false) == palette.rowNumberText)
        }
    }

    @Test("A theme's selection replaces the row's fill as declared, focused and unfocused")
    func themedSelectionFill() throws {
        try adopting([.gridSelection: "#FF0000", .gridInactiveSelection: "#0000FF"]) {
            let focused = try centerColor(of: selected(DataGridRowView(frame: Self.rowFrame), emphasized: true))
            let unfocused = try centerColor(of: selected(DataGridRowView(frame: Self.rowFrame), emphasized: false))

            #expect(focused.alphaComponent > 0.99, "the focused selection is a wash: \(focused)")
            #expect(focused.redComponent > 0.9 && focused.greenComponent < 0.2 && focused.blueComponent < 0.2, "\(focused)")
            #expect(unfocused.alphaComponent > 0.99, "the unfocused selection is a wash: \(unfocused)")
            #expect(unfocused.blueComponent > 0.9 && unfocused.redComponent < 0.2, "\(unfocused)")
        }
    }

    @Test("A theme's selection and its text reach the cells and the row-number gutter")
    func themedSelectionReachesCellsAndGutter() throws {
        try adopting([.gridSelection: "#202020", .gridSelectionText: "#00FF00"]) {
            let engine = ThemeEngine.shared
            let selectionText = engine.resolved[.gridSelectionText]
            let aqua = try #require(NSAppearance(named: .aqua))
            let palette = engine.dataGridCellPalette(in: aqua)
            let selectedCell = cellAppearance(palette: palette, onEmphasizedSelection: true)
            let plainCell = cellAppearance(palette: palette, onEmphasizedSelection: false)

            #expect(palette.selectionText == selectionText)
            #expect(selectedCell.textColor == selectionText)
            #expect(selectedCell.focusColor == selectionText)
            #expect(plainCell.textColor == palette.text)
            #expect(palette.rowNumberColor(for: .empty, onEmphasizedSelection: true) == selectionText)
            #expect(DataGridBodyChrome.selectionColor(emphasized: true) == engine.resolved[.gridSelection])
            #expect(DataGridBodyChrome.themedSelectionColor(emphasized: true) == engine.resolved[.gridSelection])
            #expect(DataGridBodyChrome.themedSelectionColor(emphasized: false) == nil)
        }
    }

    @Test("Cells a range covers under a theme's selection take its selection text, like a selected row")
    func themedRangeSelectionRecolorsItsCells() throws {
        let grid = makeGrid()
        grid.coordinator.selectionController.selectEntireColumn(0, totalRows: 3)
        let row = try #require(grid.tableView.rowView(atRow: 1, makeIfNecessary: true) as? DataGridRowView)
        row.isEmphasized = true
        let firstDataColumn = try #require(grid.coordinator.tableColumnIndex(forDisplayPosition: 0))

        #expect(row.themedRangeColumns().isEmpty, "Under the default theme a range keeps its tint and the cell text")

        try adopting([.gridSelection: "#000000", .gridSelectionText: "#FFFFFF"]) {
            #expect(row.themedRangeColumns() == [firstDataColumn])
            row.isEmphasized = false
            #expect(row.themedRangeColumns().isEmpty, "An unfocused range draws normal text, like an unfocused row")
        }
    }

    // MARK: - Header

    @Test("Under the default theme the header draws in AppKit's header colors")
    func defaultHeaderColors() throws {
        try adopting([:]) {
            let cell = SortableHeaderCell(textCell: "name")

            #expect(cell.foregroundColor(emphasized: false) == .headerTextColor)
            #expect(cell.foregroundColor(emphasized: true) == .alternateSelectedControlTextColor)
            #expect(SortableHeaderChrome.lineColor == .separatorColor)
            #expect(SortableHeaderChrome.backgroundColor == .controlBackgroundColor)
        }
    }

    @Test("A theme's header text, grid line and selection text reach the header")
    func themedHeaderColors() throws {
        try adopting([.gridHeaderText: "#FF0000", .gridLine: "#00FF00", .gridSelectionText: "#0000FF"]) {
            let engine = ThemeEngine.shared
            let cell = SortableHeaderCell(textCell: "name")

            #expect(cell.foregroundColor(emphasized: false) == engine.resolved[.gridHeaderText])
            #expect(cell.foregroundColor(emphasized: true) == engine.resolved[.gridSelectionText])
            #expect(SortableHeaderChrome.lineColor == engine.resolved[.gridLine])
            #expect(SortableHeaderChrome.lineColor != .separatorColor)
        }
    }

    // MARK: - Theme change

    /// `themeChanged` fires for every Accent, Highlight and Increase Contrast change too. A reload
    /// there would drop the selection and every formatted value on each of them.
    @Test("A theme change repaints the grid in place, keeping its selection, rows and formatted values")
    func themeChangeRepaintsWithoutReloading() throws {
        let grid = makeGrid()
        try withExtendedLifetime(grid.window) {
            grid.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let rowNumberColumn = grid.tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
            let rowView = try #require(grid.tableView.rowView(atRow: 0, makeIfNecessary: false))
            let numberCell = try #require(
                grid.tableView.view(atColumn: rowNumberColumn, row: 0, makeIfNecessary: false) as? NSTableCellView
            )
            let firstRow = try #require(grid.coordinator.displayRow(at: 0))
            _ = grid.coordinator.cellAppearance(row: 0, columnIndex: 0, onEmphasizedSelection: false)
            try #require(grid.coordinator.displayCache.box(forID: firstRow.id) != nil)

            try adopting([.gridLine: "#FF0000", .gridRowNumber: "#00FF00", .gridSelectionText: "#0000FF"]) {
                grid.coordinator.themeDidChange()
                let engine = ThemeEngine.shared

                #expect(grid.tableView.gridColor == engine.resolved[.gridLine])
                #expect(grid.coordinator.cellRegistry.palette.selectionText == engine.resolved[.gridSelectionText])
                #expect(numberCell.textField?.textColor == engine.resolved[.gridRowNumber])
                #expect(grid.tableView.selectedRowIndexes == IndexSet(integer: 1))
                #expect(grid.tableView.rowView(atRow: 0, makeIfNecessary: false) === rowView)
                #expect(grid.coordinator.displayCache.box(forID: firstRow.id) != nil)
            }

            try adopting([:]) {
                grid.coordinator.themeDidChange()

                #expect(grid.tableView.gridColor == .separatorColor)
                #expect(grid.coordinator.cellRegistry.palette.selectionText == .alternateSelectedControlTextColor)
            }
        }
    }
}
