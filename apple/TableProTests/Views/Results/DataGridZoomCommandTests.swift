//
//  DataGridZoomCommandTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class ZoomLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

// Stands in for the connection window, whose controller zooms the editor when nothing nearer does.
@MainActor
private final class WindowZoomFallback: NSViewController, ZoomCommandResponding {
    @objc func zoomIn(_ sender: Any?) {}
    @objc func zoomOut(_ sender: Any?) {}
}

@MainActor
private final class MountedGrid {
    let window: NSWindow
    private let host: NSHostingView<DataGridView>

    init(rowCount: Int = 2) async {
        let rows = TableRows.from(
            queryRows: (0 ..< rowCount).map { [PluginCellValue.text("value \($0)")] },
            columns: ["name"],
            columnTypes: [ColumnType.text(rawType: "TEXT")]
        )
        host = NSHostingView(rootView: DataGridView(
            tableRowsProvider: { rows },
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            configuration: DataGridConfiguration(tabType: .query),
            layoutPersister: ZoomLayoutPersister(),
            selectedRowIndices: .constant([]),
            sortState: .constant(SortState()),
            columnLayout: .constant(ColumnLayoutState())
        ))
        let fallback = WindowZoomFallback()
        fallback.view = host
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = fallback
        // A content view controller sizes the window to its view's fitting size, which for a grid is tiny.
        window.setContentSize(NSSize(width: 600, height: 300))
        await settle()
    }

    var tableView: KeyHandlingTableView? {
        Self.first(KeyHandlingTableView.self, in: host)
    }

    var scrollView: DataGridScrollView? {
        tableView?.enclosingScrollView as? DataGridScrollView
    }

    func close() {
        window.orderOut(nil)
    }

    func scroll(toRow row: Int) {
        guard let tableView else { return }
        let inset = tableView.enclosingScrollView?.contentView.contentInsets.top ?? 0
        tableView.scroll(NSPoint(x: 0, y: tableView.rect(ofRow: row).minY - inset))
    }

    // SwiftUI applies a change on a later run-loop turn, so each pass lays out and waits for one.
    private func settle() async {
        for _ in 0 ..< 10 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        for subview in view.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private func zoomResponder(from responder: NSResponder?) -> NSResponder? {
    var responder = responder
    while let current = responder, !current.responds(to: #selector(ZoomCommandResponding.zoomIn(_:))) {
        responder = current.nextResponder
    }
    return responder
}

@MainActor
private func item(_ action: Selector) -> NSMenuItem {
    NSMenuItem(title: "", action: action, keyEquivalent: "")
}

extension GlobalStateSuites {
    @Suite(.appSettings {
        $0.typography = TypographySettings(editorFontSize: 13, dataGridFontSize: 13)
        $0.dataGrid.rowHeight = .normal
    })
    @MainActor
    struct DataGridZoomCommandTests {
        @Test("From a focused grid the command reaches the grid's scroll view before the window")
        func focusedGridClaimsTheCommand() async throws {
            let grid = await MountedGrid()
            defer { grid.close() }
            let tableView = try #require(grid.tableView)
            let scrollView = try #require(grid.scrollView)

            #expect(grid.window.makeFirstResponder(tableView))

            #expect(zoomResponder(from: grid.window.firstResponder) === scrollView)
        }

        @Test("From a cell being edited the command reaches the grid, not the window")
        func cellEditorClaimsTheCommand() async throws {
            let grid = await MountedGrid()
            defer { grid.close() }
            let tableView = try #require(grid.tableView)
            let scrollView = try #require(grid.scrollView)
            let coordinator = try #require(tableView.coordinator)
            let column = try #require(coordinator.tableColumnIndex(forDisplayPosition: 0))

            coordinator.showOverlayEditor(tableView: tableView, row: 0, column: column, columnIndex: 0, value: "value")
            defer { coordinator.overlayEditor?.dismiss(commit: false) }

            #expect(grid.window.firstResponder is NSTextView)
            #expect(zoomResponder(from: grid.window.firstResponder) === scrollView)
        }

        @Test("Zoom In and Zoom Out change the Data Grid font and leave the editor font")
        func zoomChangesTheGridFontOnly() {
            let scrollView = DataGridScrollView()

            scrollView.zoomIn(nil)
            #expect(AppSettingsManager.shared.typography.dataGridFontSize == 14)
            #expect(AppSettingsManager.shared.typography.editorFontSize == 13)

            scrollView.zoomOut(nil)
            scrollView.zoomOut(nil)
            #expect(AppSettingsManager.shared.typography.dataGridFontSize == 12)
            #expect(AppSettingsManager.shared.typography.editorFontSize == 13)
        }

        @Test(
            "Zoom In dims at the largest size instead of falling through to the editor",
            .appSettings { $0.typography.dataGridFontSize = TypographySettings.sizeRange.upperBound }
        )
        func zoomInDimsAtTheLargestSize() {
            let scrollView = DataGridScrollView()

            #expect(!scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomIn(_:)))))
            #expect(scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomOut(_:)))))

            scrollView.zoomIn(nil)
            #expect(AppSettingsManager.shared.typography.dataGridFontSize == TypographySettings.sizeRange.upperBound)
            #expect(AppSettingsManager.shared.typography.editorFontSize == 13)
        }

        @Test(
            "Zoom Out dims at the smallest size",
            .appSettings { $0.typography.dataGridFontSize = TypographySettings.sizeRange.lowerBound }
        )
        func zoomOutDimsAtTheSmallestSize() {
            let scrollView = DataGridScrollView()

            #expect(scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomIn(_:)))))
            #expect(!scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomOut(_:)))))
        }

        @Test(
            "A font taller than the chosen row height grows the rows of an open grid",
            .appSettings {
                $0.typography.dataGridFontSize = TypographySettings.sizeRange.upperBound - 1
                $0.dataGrid.rowHeight = .compact
            }
        )
        func rowsGrowWithTheFont() async throws {
            let grid = await MountedGrid()
            defer { grid.close() }
            let tableView = try #require(grid.tableView)
            let scrollView = try #require(grid.scrollView)
            let before = tableView.rowHeight
            #expect(before > CGFloat(DataGridRowHeight.compact.rawValue))

            scrollView.zoomIn(nil)

            let font = ThemeEngine.shared.dataGridFonts.regular
            try await waitUntil { tableView.rowHeight == DataGridMetrics.rowHeight(.compact, font: font) }
            #expect(tableView.rowHeight > before)
            #expect(tableView.rowHeight >= font.ascender - font.descender + font.leading)
        }

        @Test(
            "Rows that grow with a zoom keep the first visible row in place",
            .appSettings { $0.typography.dataGridFontSize = 20 }
        )
        func zoomKeepsTheFirstVisibleRow() async throws {
            let grid = await MountedGrid(rowCount: 10_000)
            defer { grid.close() }
            let tableView = try #require(grid.tableView)
            let scrollView = try #require(grid.scrollView)
            let coordinator = try #require(tableView.coordinator)
            grid.scroll(toRow: 5_000)
            let before = try #require(coordinator.viewportSample())
            try #require(before.firstVisibleRow > 4_000)
            let rowHeight = tableView.rowHeight

            scrollView.zoomIn(nil)

            try await waitUntil { tableView.rowHeight != rowHeight }
            let after = try #require(coordinator.viewportSample())
            #expect(after.firstVisibleRow == before.firstVisibleRow)
        }

        // Enough rows that the row-number column widens with the font, and a size where the rows grow:
        // both are geometry changes that otherwise end the edit.
        @Test(
            "An open cell editor keeps its text and focus through a zoom, at the new size and on its cell",
            .appSettings { $0.typography.dataGridFontSize = 20 }
        )
        func openEditorFollowsTheFont() async throws {
            let grid = await MountedGrid(rowCount: 10_000)
            defer { grid.close() }
            let tableView = try #require(grid.tableView)
            let scrollView = try #require(grid.scrollView)
            let coordinator = try #require(tableView.coordinator)
            let column = try #require(coordinator.tableColumnIndex(forDisplayPosition: 0))
            let rowNumbers = try #require(tableView.tableColumns.first { $0.identifier == ColumnIdentitySchema.rowNumberIdentifier })
            let rowNumberWidth = rowNumbers.width
            let rowHeight = tableView.rowHeight
            grid.scroll(toRow: 5_000)
            let editedRow = 5_005
            try #require(NSLocationInRange(editedRow, tableView.rows(in: tableView.visibleRect)))
            coordinator.showOverlayEditor(tableView: tableView, row: editedRow, column: column, columnIndex: 0, value: "value")
            let editor = try #require(coordinator.overlayEditor)
            defer { editor.dismiss(commit: false) }
            let textView = try #require(grid.window.firstResponder as? NSTextView)
            let container = try #require(editor.containerView)
            textView.string = "edited"

            scrollView.zoomIn(nil)

            try await waitUntil { textView.font == ThemeEngine.shared.valueFont }
            try #require(rowNumbers.width != rowNumberWidth)
            try #require(tableView.rowHeight != rowHeight)
            #expect(editor.isActive)
            #expect(textView.string == "edited")
            #expect(grid.window.firstResponder === textView)
            #expect(NSLocationInRange(editedRow, tableView.rows(in: tableView.visibleRect)))
            let cellFrame = CellOverlayBase.displayedCellFrame(in: tableView, column: column, row: editedRow)
            let expected = scrollView.convert(CellOverlayBase.overlayFrame(for: cellFrame, value: "edited"), from: tableView)
            #expect(container.frame == expected)
        }
    }
}

struct DataGridRowHeightTests {
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
