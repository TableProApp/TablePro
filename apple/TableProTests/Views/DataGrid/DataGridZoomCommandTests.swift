//
//  DataGridZoomCommandTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private func zoomResponder(from responder: NSResponder?) -> NSResponder? {
    var responder = responder
    while let current = responder, !current.responds(to: #selector(ZoomCommandResponding.zoomIn(_:))) {
        responder = current.nextResponder
    }
    return responder
}

@MainActor
private func menuItem(_ action: Selector) -> NSMenuItem {
    NSMenuItem(title: "", action: action, keyEquivalent: "")
}

@MainActor
private func zoomRows(_ count: Int) -> TableRows {
    TableRows.from(
        queryRows: (0..<count).map { [PluginCellValue.text("value \($0)")] },
        columns: ["name"],
        columnTypes: [.text(rawType: "TEXT")]
    )
}

extension GlobalStateSuites {
    @Suite(.appSettings {
        $0.typography = TypographySettings(editorFontSize: 13, dataGridFontSize: 13)
        $0.dataGrid.rowHeight = .normal
    })
    @MainActor
    struct DataGridZoomCommandTests {
        @Test("From a focused grid the command reaches the grid's table before the window")
        func focusedGridClaimsTheCommand() {
            let grid = HostedDataGrid(rows: zoomRows(2))
            defer { grid.close() }

            #expect(grid.focus())

            #expect(zoomResponder(from: grid.window.firstResponder) === grid.main)
        }

        @Test("Zoom In and Zoom Out change the Data Grid font and leave the editor font")
        func zoomChangesTheGridFontOnly() {
            let table = DataGridTableView(frame: .zero)

            table.zoomIn(nil)
            #expect(AppSettingsManager.shared.typography.dataGridFontSize == 14)
            #expect(AppSettingsManager.shared.typography.editorFontSize == 13)

            table.zoomOut(nil)
            table.zoomOut(nil)
            #expect(AppSettingsManager.shared.typography.dataGridFontSize == 12)
            #expect(AppSettingsManager.shared.typography.editorFontSize == 13)
        }

        @Test(
            "Zoom In dims at the largest size instead of falling through to the editor",
            .appSettings { $0.typography.dataGridFontSize = TypographySettings.sizeRange.upperBound }
        )
        func zoomInDimsAtTheLargestSize() {
            let table = DataGridTableView(frame: .zero)

            #expect(!table.validateUserInterfaceItem(menuItem(#selector(ZoomCommandResponding.zoomIn(_:)))))
            #expect(table.validateUserInterfaceItem(menuItem(#selector(ZoomCommandResponding.zoomOut(_:)))))

            table.zoomIn(nil)
            #expect(AppSettingsManager.shared.typography.dataGridFontSize == TypographySettings.sizeRange.upperBound)
            #expect(AppSettingsManager.shared.typography.editorFontSize == 13)
        }

        @Test(
            "Zoom Out dims at the smallest size",
            .appSettings { $0.typography.dataGridFontSize = TypographySettings.sizeRange.lowerBound }
        )
        func zoomOutDimsAtTheSmallestSize() {
            let table = DataGridTableView(frame: .zero)

            #expect(table.validateUserInterfaceItem(menuItem(#selector(ZoomCommandResponding.zoomIn(_:)))))
            #expect(!table.validateUserInterfaceItem(menuItem(#selector(ZoomCommandResponding.zoomOut(_:)))))
        }

        @Test(
            "A font taller than the chosen row height grows the rows of both panes of an open grid",
            .appSettings {
                $0.typography.dataGridFontSize = TypographySettings.sizeRange.upperBound - 1
                $0.dataGrid.rowHeight = .compact
            }
        )
        func rowsGrowWithTheFont() async throws {
            let grid = HostedDataGrid(rows: zoomRows(2))
            defer { grid.close() }
            let before = grid.main.rowHeight
            #expect(before > CGFloat(DataGridRowHeight.compact.rawValue))

            grid.main.zoomIn(nil)

            let font = ThemeEngine.shared.dataGridFonts.regular
            let expected = DataGridMetrics.rowHeight(.compact, font: font)
            try await waitUntil { grid.main.rowHeight == expected && grid.main.rowHeight > before }
            #expect(grid.main.rowHeight >= font.ascender - font.descender + font.leading)
            #expect(grid.frozen.rowHeight == grid.main.rowHeight)
        }

        @Test(
            "Rows that grow with a zoom keep the first visible row in place",
            .appSettings { $0.typography.dataGridFontSize = 20 }
        )
        func zoomKeepsTheFirstVisibleRow() async throws {
            let grid = HostedDataGrid(rows: zoomRows(10_000))
            defer { grid.close() }
            let table = grid.main
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 5_000).minY - grid.controller.headerInset))
            let before = try #require(grid.controller.viewportSample())
            try #require(before.row > 4_000)
            let rowHeight = table.rowHeight

            table.zoomIn(nil)

            try await waitUntil { table.rowHeight != rowHeight }
            #expect(grid.controller.viewportSample()?.row == before.row)
        }

        @Test("The row height setting stands while the font fits in it")
        func settingStandsForAFittingFont() {
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            #expect(DataGridMetrics.rowHeight(.normal, font: font) == CGFloat(DataGridRowHeight.normal.rawValue))
            #expect(DataGridMetrics.rowHeight(.compact, font: font) == CGFloat(DataGridRowHeight.compact.rawValue))
        }

        @Test("A font taller than the row raises the row to hold the whole line")
        func tallFontRaisesTheRow() {
            let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
            let height = DataGridMetrics.rowHeight(.normal, font: font)
            #expect(height > CGFloat(DataGridRowHeight.normal.rawValue))
            #expect(height >= font.ascender - font.descender + font.leading)
            #expect(height == height.rounded())
        }
    }
}
