//
//  DataGridWordWrapTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private let heightOfRow = #selector(NSTableViewDelegate.tableView(_:heightOfRow:))

@MainActor
private func wrapRows(_ count: Int, long: Set<Int>, text: String = String(repeating: "word ", count: 30)) -> TableRows {
    TableRows.from(
        queryRows: (0..<count).map { [PluginCellValue.text(String($0)), .text(long.contains($0) ? text : "short")] },
        columns: ["id", "note"],
        columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
    )
}

@MainActor
private func wrapStore(wraps: Bool) -> InMemoryDataGridStateStore {
    let store = InMemoryDataGridStateStore(columnLayout: ColumnLayoutState(columnWidths: ["id": 60, "note": 160]))
    store.wrapsText = wraps
    return store
}

@MainActor
private func wrapConfiguration(isEditable: Bool = false) -> DataGridConfiguration {
    var configuration = DataGridConfiguration()
    configuration.commands = [.wrapText]
    configuration.isEditable = isEditable
    return configuration
}

@MainActor
private func wrapGrid(_ rows: TableRows, wraps: Bool = true) -> HostedDataGrid {
    HostedDataGrid(rows: rows, configuration: wrapConfiguration(), store: wrapStore(wraps: wraps))
}

extension GlobalStateSuites {
    @Suite(.appSettings {
        $0.typography = TypographySettings(editorFontSize: 13, dataGridFontSize: 13)
        $0.dataGrid.rowHeight = .normal
        $0.dataGrid.showInvisibleCharacters = false
    })
    @MainActor
    struct DataGridWordWrapTests {
        private func lineHeight() -> CGFloat {
            DataGridMetrics.lineHeight(of: ThemeEngine.shared.dataGridFonts.regular)
        }

        @Test("A grid that does not wrap answers no row heights and keeps the fixed pitch")
        func wrapOffIsTheFixedPitchTable() {
            let grid = wrapGrid(wrapRows(5, long: [1]), wraps: false)
            defer { grid.close() }

            #expect(!grid.controller.responds(to: heightOfRow))
            #expect(!grid.controller.wrapsText)
            #expect(grid.main.rect(ofRow: 1).height == grid.main.rowHeight)
            #expect(grid.model.display.lineCounts.isEmpty)
        }

        @Test("A grid whose store wraps but that does not offer the command stays fixed pitch")
        func wrapNeedsTheCommand() {
            let grid = HostedDataGrid(rows: wrapRows(5, long: [1]), store: wrapStore(wraps: true))
            defer { grid.close() }

            #expect(!grid.model.wrapsText)
            #expect(!grid.controller.responds(to: heightOfRow))
            grid.model.setWrapsText(false)
            #expect(grid.main.rect(ofRow: 1).height == grid.main.rowHeight)
        }

        @Test("A long value makes its row taller in both panes, and a short row keeps the one-line height")
        func longRowGrowsInBothPanes() throws {
            let grid = wrapGrid(wrapRows(5, long: [1]))
            defer { grid.close() }

            #expect(grid.controller.responds(to: heightOfRow))
            let lines = try #require(grid.model.display.lineCounts[.existing(1)])
            #expect(lines > 1)
            let expected = DataGridMetrics.wrappedRowHeight(lines: lines, rowHeight: grid.main.rowHeight, lineHeight: lineHeight())
            #expect(grid.main.rect(ofRow: 1).height == expected)
            #expect(grid.frozen.rect(ofRow: 1).height == expected)
            #expect(grid.main.rect(ofRow: 0).height == grid.main.rowHeight)
            #expect(grid.main.rect(ofRow: 2).minY == grid.frozen.rect(ofRow: 2).minY)
        }

        @Test("A row stops growing at ten lines")
        func rowIsCappedAtTenLines() {
            let grid = wrapGrid(wrapRows(3, long: [1], text: String(repeating: "word ", count: 600)))
            defer { grid.close() }

            #expect(grid.model.display.lineCounts[.existing(1)] == DataGridWrapLayout.maximumLines)
            #expect(grid.main.rect(ofRow: 1).height == grid.main.rowHeight + 9 * lineHeight())
        }

        @Test("A line break in the value is a line of the row")
        func lineBreaksAddLines() {
            let grid = wrapGrid(wrapRows(3, long: [1], text: "a\r\nb\u{2028}c"))
            defer { grid.close() }

            #expect(grid.model.display.lineCounts[.existing(1)] == 3)
        }

        @Test("Widening the column shortens the row once the resize lands")
        func resizeMeasuresTheRowsAgain() throws {
            let grid = wrapGrid(wrapRows(5, long: [1]))
            defer { grid.close() }
            let before = grid.main.rect(ofRow: 1).height
            let column = try #require(grid.tableColumn(named: "note"))

            column.width = 900
            grid.controller.columnDidResize(column, in: grid.controller.main)
            grid.layout()

            let after = grid.main.rect(ofRow: 1).height
            #expect(after < before)
            #expect(after > grid.main.rowHeight)
            #expect(grid.frozen.rect(ofRow: 1).height == after)
        }

        @Test("Turning wrap on and off keeps the first visible row and swaps the height path")
        func toggleKeepsTheFirstVisibleRow() throws {
            let rows = wrapRows(2_000, long: Set(stride(from: 0, to: 2_000, by: 3)))
            let grid = wrapGrid(rows, wraps: false)
            defer { grid.close() }
            let table = grid.main
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 1_000).minY - grid.controller.headerInset))
            let before = try #require(grid.controller.viewportSample())
            try #require(before.row > 900)

            grid.model.setWrapsText(true)
            grid.layout()

            #expect(grid.controller.responds(to: heightOfRow))
            #expect(grid.controller.viewportSample()?.row == before.row)
            #expect(table.rect(ofRow: 1_002).height > table.rowHeight)

            grid.model.setWrapsText(false)
            grid.layout()

            #expect(!grid.controller.responds(to: heightOfRow))
            #expect(grid.controller.viewportSample()?.row == before.row)
            #expect(table.rect(ofRow: 1_002).height == table.rowHeight)
            #expect(grid.model.display.lineCounts.isEmpty)
        }

        @Test("A row scrolled to past the prewarm window is measured as it arrives, with the prewarm paused")
        func rowEnteringTheViewportIsMeasured() {
            let grid = wrapGrid(wrapRows(3_000, long: [2_000]))
            defer { grid.close() }
            grid.controller.pausePrewarm()
            #expect(grid.model.display.lineCounts[.existing(2_000)] == nil)

            let table = grid.main
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 2_000).minY - grid.controller.headerInset))

            #expect(grid.model.display.lineCounts[.existing(2_000)] != nil)
            #expect(table.rect(ofRow: 2_000).height > table.rowHeight)
            #expect(grid.frozen.rect(ofRow: 2_000).height == table.rect(ofRow: 2_000).height)
        }

        @Test("The frozen pane shows the main pane's first row after a jump, whatever the rows above measure")
        func frozenPaneFollowsByRow() throws {
            let grid = wrapGrid(wrapRows(3_000, long: Set(stride(from: 0, to: 3_000, by: 2))))
            defer { grid.close() }
            let table = grid.main
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 1_500).minY - grid.controller.headerInset))
            grid.layout()

            let sample = try #require(grid.controller.viewportSample())
            let frozen = grid.frozen
            let inset = grid.frozenScrollView.contentView.contentInsets.top
            let frozenTop = grid.frozenScrollView.contentView.bounds.minY + inset
            let offset = frozenTop - frozen.rect(ofRow: sample.row).minY
            #expect(abs(offset - sample.offset) <= 1)
        }

        @Test("A value that gets shorter gives its row the one-line height back")
        func updatedRowIsMeasuredAgain() {
            let grid = wrapGrid(wrapRows(5, long: [1]))
            defer { grid.close() }
            #expect(grid.main.rect(ofRow: 1).height > grid.main.rowHeight)

            _ = grid.owner.tableRows.edit(row: 1, column: 1, value: .text("x"))
            grid.model.apply(.cellChanged(row: 1, column: 1))
            grid.layout()

            #expect(grid.main.rect(ofRow: 1).height == grid.main.rowHeight)
            #expect(grid.frozen.rect(ofRow: 1).height == grid.main.rowHeight)
        }

        @Test("The first visible row stays at the top of the viewport when its own height changes")
        func firstVisibleRowKeepsItsTopWhenItChanges() throws {
            let grid = wrapGrid(wrapRows(400, long: [201]))
            defer { grid.close() }
            let table = grid.main
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 200).minY - grid.controller.headerInset))
            grid.layout()
            let before = try #require(grid.controller.viewportSample())
            try #require(before.row == 200)

            _ = grid.owner.tableRows.edit(row: 200, column: 1, value: .text(String(repeating: "word ", count: 30)))
            grid.model.apply(.cellChanged(row: 200, column: 1))
            grid.layout()

            #expect(table.rect(ofRow: 200).height > table.rowHeight)
            var sample = try #require(grid.controller.viewportSample())
            #expect(sample.row == 200)
            #expect(abs(sample.offset - before.offset) <= 1)

            _ = grid.owner.tableRows.edit(row: 200, column: 1, value: .text("x"))
            grid.model.apply(.cellChanged(row: 200, column: 1))
            grid.layout()

            #expect(table.rect(ofRow: 200).height == table.rowHeight)
            sample = try #require(grid.controller.viewportSample())
            #expect(sample.row == 200)
            #expect(abs(sample.offset - before.offset) <= 1)
        }

        @Test("The edit field of a cell in a tall row sits on the row's first line")
        func editFieldSitsOnTheFirstLine() throws {
            let grid = EditingGrid(
                rows: wrapRows(3, long: [1]),
                configuration: wrapConfiguration(isEditable: true),
                store: wrapStore(wraps: true)
            )
            defer { grid.tearDown() }
            let table = grid.controller.main.tableView
            try #require(table.rect(ofRow: 1).height > table.rowHeight)

            #expect(grid.controller.beginEditingCell(row: 1, displayColumn: 0))

            #expect(grid.cellView.bounds.height == table.rect(ofRow: 1).height)
            #expect(grid.cellView.field.frame.maxY <= table.rowHeight)
            #expect(grid.cellView.field.frame.minY >= 0)
        }

        @Test("An accessibility stand-in in a tall row is as tall as the row")
        func standInCoversTheTallRow() async throws {
            let wasActive = DataGridAccessibility.isActive
            DataGridAccessibility.isActive = true
            defer { DataGridAccessibility.isActive = wasActive }
            let grid = wrapGrid(wrapRows(5, long: [1]))
            defer { grid.close() }
            let index = try #require(grid.tableIndex(ofDisplayPosition: 1))

            grid.controller.remountAccessibilityCells()
            try await waitUntil { grid.main.view(atColumn: index, row: 1, makeIfNecessary: false) is DataGridAccessibilityCellView }

            grid.layout()
            let standIn = try #require(grid.main.view(atColumn: index, row: 1, makeIfNecessary: false))
            #expect(standIn.frame.height == grid.main.rect(ofRow: 1).height)
        }

        @Test("The header menu offers Wrap Text with a checkmark, only on a grid that offers the command")
        func headerMenuOffersWrapText() throws {
            let grid = wrapGrid(wrapRows(3, long: [1]))
            defer { grid.close() }
            let column = try #require(grid.model.columns.column(at: 1))
            let action = #selector(DataGridViewController.toggleWrapText(_:))

            let item = try #require(grid.controller.headerMenu(for: column)?.items.first { $0.action == action })
            #expect(item.title == String(localized: "Wrap Text"))
            #expect(item.state == .on)
            #expect(grid.controller.validateMenuItem(item))

            grid.controller.toggleWrapText(item)
            #expect(!grid.model.wrapsText)
            let off = try #require(grid.controller.headerMenu(for: column)?.items.first { $0.action == action })
            #expect(off.state == .off)

            let plain = HostedDataGrid(rows: wrapRows(3, long: [1]))
            defer { plain.close() }
            let plainColumn = try #require(plain.model.columns.column(at: 1))
            let offersIt = plain.controller.headerMenu(for: plainColumn)?.items.contains { $0.action == action } ?? false
            #expect(!offersIt)
        }

        @Test("The View menu's item is checked by the focused grid, and dimmed by a grid that does not wrap")
        func viewMenuItemIsValidatedByTheGrid() {
            let grid = wrapGrid(wrapRows(3, long: [1]))
            defer { grid.close() }
            let item = NSMenuItem(title: "", action: #selector(DataGridViewController.toggleWrapText(_:)), keyEquivalent: "")

            #expect(grid.controller.validateMenuItem(item))
            #expect(item.state == .on)

            let plain = HostedDataGrid(rows: wrapRows(3, long: [1]))
            defer { plain.close() }
            #expect(!plain.controller.validateMenuItem(item))
            #expect(item.state == .off)
        }
    }
}
