import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class OverlayAccessibilityLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Cell overlay accessibility", .serialized)
@MainActor
struct CellOverlayAccessibilityTests {
    private struct Grid {
        let window: NSWindow
        let coordinator: TableViewCoordinator
        let tableView: KeyHandlingTableView
        let scrollView: NSScrollView
        let dataColumn: Int
    }

    private func makeGrid(isEditable: Bool) throws -> Grid {
        let columns = ["third_col"]
        let columnTypes = [ColumnType.text(rawType: "TEXT")]
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: isEditable,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: OverlayAccessibilityLayoutPersister()
        )
        let tableRows = TableRows.from(
            queryRows: [[PluginCellValue.text("3")]],
            columns: columns,
            columnTypes: columnTypes
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 21
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
            isEditable: isEditable,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 120 }
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())
        return Grid(
            window: window,
            coordinator: coordinator,
            tableView: tableView,
            scrollView: scrollView,
            dataColumn: dataColumn
        )
    }

    private func openViewer(in grid: Grid) throws -> CellOverlayViewer {
        grid.coordinator.showOverlayViewer(
            tableView: grid.tableView,
            row: 0,
            column: grid.dataColumn,
            columnIndex: 0,
            value: "3"
        )
        return try #require(grid.coordinator.overlayViewer)
    }

    private func textView(of overlay: CellOverlayBase) throws -> NSTextView {
        let container = try #require(overlay.containerView)
        let scrollView = try #require(container.subviews.first as? NSScrollView)
        return try #require(scrollView.documentView as? NSTextView)
    }

    private func publishedDescendants(of element: Any, depth: Int = 0) -> [Any] {
        guard depth < 12,
              let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() else { return [] }
        let published = NSAccessibility.unignoredChildren(from: children)
        return published + published.flatMap { publishedDescendants(of: $0, depth: depth + 1) }
    }

    private func isPublished(_ textView: NSTextView, from window: NSWindow) -> Bool {
        publishedDescendants(of: window).contains { ($0 as AnyObject) === textView }
    }

    private func isSameElement(_ element: Any?, as expected: AnyObject) -> Bool {
        guard let element else { return false }
        return (element as AnyObject) === expected
    }

    private func withActiveAccessibility(_ body: () throws -> Void) rethrows {
        let wasActive = DataGridAccessibility.isActive
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = wasActive }
        try body()
    }

    @Test("An open cell viewer is reachable by walking the window's accessibility tree")
    func anOpenViewerIsInTheTree() throws {
        try withActiveAccessibility {
            let grid = try makeGrid(isEditable: false)
            let viewer = try openViewer(in: grid)
            defer { viewer.dismiss() }
            let text = try textView(of: viewer)

            #expect(isPublished(text, from: grid.window))
            #expect(text.accessibilityRole() == .textArea)
            #expect(text.accessibilityValue() as? String == "3")
        }
    }

    @Test("An open cell editor is reachable by walking the window's accessibility tree")
    func anOpenEditorIsInTheTree() throws {
        try withActiveAccessibility {
            let grid = try makeGrid(isEditable: true)
            grid.coordinator.beginCellEdit(row: 0, tableColumnIndex: grid.dataColumn)
            let editor = try #require(grid.coordinator.overlayEditor)
            defer { editor.dismiss(commit: false) }
            let text = try textView(of: editor)

            #expect(isPublished(text, from: grid.window))
            #expect(text.accessibilityRole() == .textArea)
            #expect(text.accessibilityValue() as? String == "3")
        }
    }

    @Test("The overlay is mounted in the grid's scroll view, outside the table that cannot publish it")
    func theOverlayIsMountedOutsideTheTable() throws {
        let grid = try makeGrid(isEditable: false)
        let viewer = try openViewer(in: grid)
        defer { viewer.dismiss() }
        let container = try #require(viewer.containerView)
        let overlayScrollView = try #require(container.subviews.first as? NSScrollView)

        #expect(container.superview === grid.scrollView)
        #expect(!container.isDescendant(of: grid.tableView))
        let parent = overlayScrollView.accessibilityParent()
        #expect(isSameElement(parent.flatMap { NSAccessibility.unignoredAncestor(of: $0) }, as: grid.scrollView))
    }

    @Test("The overlay sits over the rows and under the header, the scrollers and the row gutter")
    func theOverlayStacksDirectlyAboveTheRows() throws {
        let grid = try makeGrid(isEditable: false)
        DataGridView.installRowGutter(
            scrollView: grid.scrollView,
            tableView: grid.tableView,
            coordinator: grid.coordinator
        )
        let gutter = try #require(grid.coordinator.rowGutter)
        defer { gutter.detachTableGeometryObserver() }
        let viewer = try openViewer(in: grid)
        defer { viewer.dismiss() }
        let container = try #require(viewer.containerView)
        let subviews = grid.scrollView.subviews
        let clipIndex = try #require(subviews.firstIndex { $0 === grid.scrollView.contentView })
        let overlayIndex = try #require(subviews.firstIndex { $0 === container })
        let headerClip = try #require(grid.tableView.headerView?.superview)
        let headerIndex = try #require(subviews.firstIndex { $0 === headerClip })
        let scroller = try #require(grid.scrollView.verticalScroller)
        let scrollerIndex = try #require(subviews.firstIndex { $0 === scroller })
        let gutterIndex = try #require(subviews.firstIndex { gutter.isDescendant(of: $0) })

        #expect(overlayIndex == clipIndex + 1)
        #expect(overlayIndex < headerIndex)
        #expect(overlayIndex < scrollerIndex)
        #expect(overlayIndex < gutterIndex)
    }

    @Test("The overlay lies over the cell it opened on")
    func theOverlayCoversItsCell() throws {
        let grid = try makeGrid(isEditable: false)
        let viewer = try openViewer(in: grid)
        defer { viewer.dismiss() }
        let container = try #require(viewer.containerView)
        let cell = grid.tableView.frameOfCell(atColumn: grid.dataColumn, row: 0)

        let overlayInTable = grid.tableView.convert(container.frame, from: grid.scrollView)

        #expect(overlayInTable.origin == cell.origin)
        #expect(overlayInTable.width == cell.width)
        #expect(overlayInTable.height >= cell.height)
    }

    @Test("A dismissed overlay leaves nothing mounted or published")
    func aDismissedOverlayLeavesNothingBehind() throws {
        try withActiveAccessibility {
            let grid = try makeGrid(isEditable: false)
            let viewer = try openViewer(in: grid)
            let container = try #require(viewer.containerView)
            let text = try textView(of: viewer)

            viewer.dismiss()

            #expect(container.superview == nil)
            #expect(!isPublished(text, from: grid.window))
        }
    }

    @Test("The element a hit test over an open overlay returns is one the tree publishes")
    func theHitTestResultOverTheOverlayIsInTheTree() throws {
        try withActiveAccessibility {
            let grid = try makeGrid(isEditable: false)
            let viewer = try openViewer(in: grid)
            defer { viewer.dismiss() }
            let container = try #require(viewer.containerView)
            let text = try textView(of: viewer)
            let centre = NSPoint(x: container.bounds.midX, y: container.bounds.midY)
            let onScreen = grid.window.convertPoint(toScreen: container.convert(centre, to: nil))

            let hit = grid.window.accessibilityHitTest(onScreen)

            #expect(isSameElement(hit, as: text))
            #expect(isPublished(text, from: grid.window))
        }
    }
}
