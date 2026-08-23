//
//  SortableHeaderRenderingTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("SortableHeaderView chrome rendering")
@MainActor
struct SortableHeaderRenderingTests {
    private struct Grid {
        let window: NSWindow
        let tableView: NSTableView
        let headerView: SortableHeaderView
        let headerCells: [SortableHeaderCell]
        let schema: ColumnIdentitySchema

        var headerCell: SortableHeaderCell { headerCells[0] }
    }

    private static let contentWidth: CGFloat = 400
    private static let columnAreaWidth: CGFloat = 360

    private func makeGrid(comment: String?, columns: [String] = ["code"]) -> Grid {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200))
        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.style = .plain

        let schema = ColumnIdentitySchema(columns: columns)
        var cells: [SortableHeaderCell] = []
        var comments: [NSUserInterfaceItemIdentifier: String] = [:]
        for (index, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(index))
            column.width = Self.columnAreaWidth / CGFloat(columns.count)
            let headerCell = SortableHeaderCell(textCell: name)
            headerCell.font = column.headerCell.font
            column.headerCell = headerCell
            cells.append(headerCell)
            if let comment {
                comments[column.identifier] = comment
            }
            tableView.addTableColumn(column)
        }

        let headerView = SortableHeaderView(frame: tableView.headerView?.frame ?? .zero)
        tableView.headerView = headerView
        scrollView.documentView = tableView

        let window = makeWindow(content: scrollView)

        if comment != nil {
            headerView.updateComments(comments)
            headerView.showsComments = true
        }

        scrollView.tile()
        window.layoutIfNeeded()
        return Grid(
            window: window,
            tableView: tableView,
            headerView: headerView,
            headerCells: cells,
            schema: schema
        )
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        window.layoutIfNeeded()
        return window
    }

    private func sortState(column: Int, direction: SortDirection = .ascending) -> SortState {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: column, direction: direction)]
        return state
    }

    private func brightnessColumn(of view: NSView, atX sampleX: CGFloat) -> [CGFloat] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let x = min(rep.pixelsWide - 1, Int(sampleX * scale))
        return (0 ..< rep.pixelsHigh).map { rep.colorAt(x: x, y: $0)?.brightnessComponent ?? 0 }
    }

    private func ruleOffsets(in view: NSView, atX sampleX: CGFloat = 300) -> [CGFloat] {
        let brightness = brightnessColumn(of: view, atX: sampleX)
        guard !brightness.isEmpty else { return [] }
        let scale = CGFloat(brightness.count) / view.bounds.height
        let span = max(1, Int((3 * scale).rounded()))
        return brightness.indices.compactMap { index in
            guard abs(brightness[index] - brightness[max(0, index - span)]) > 0.02 else { return nil }
            return CGFloat(index) / scale
        }
    }

    private func isAlongBottomEdge(_ offset: CGFloat, of view: NSView) -> Bool {
        offset >= view.bounds.height - SortableHeaderChrome.separatorThickness
    }

    @Test("The comment header draws its only horizontal rule along the bottom edge")
    func commentHeaderRuleSitsAlongBottomEdge() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let offsets = ruleOffsets(in: grid.headerView)

        #expect(!offsets.isEmpty)
        #expect(offsets.allSatisfy { isAlongBottomEdge($0, of: grid.headerView) })
    }

    @Test("The comment header draws no horizontal rule across the comment line")
    func commentHeaderDrawsNoRuleAcrossTheCommentLine() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let naturalHeight = grid.headerView.commentHeaderHeight - SortableHeaderCell.commentLineHeight
        let centredBandBottom = (grid.headerView.commentHeaderHeight + naturalHeight) / 2
            - SortableHeaderChrome.separatorThickness

        let offsets = ruleOffsets(in: grid.headerView)

        #expect(!offsets.contains { abs($0 - centredBandBottom) < 1 })
    }

    @Test("The bottom rule spans past the trailing edge of the last column")
    func bottomRuleSpansPastTheLastColumn() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let offsets = ruleOffsets(in: grid.headerView, atX: 390)

        #expect(!offsets.isEmpty)
        #expect(offsets.allSatisfy { isAlongBottomEdge($0, of: grid.headerView) })
    }

    @Test("The natural height header keeps its rule along the bottom edge")
    func naturalHeaderRuleSitsAlongBottomEdge() {
        let grid = makeGrid(comment: nil)
        let offsets = ruleOffsets(in: grid.headerView)

        #expect(!offsets.isEmpty)
        #expect(offsets.allSatisfy { isAlongBottomEdge($0, of: grid.headerView) })
    }

    @Test("Selecting a column highlights the full height of the comment header")
    func selectionHighlightSpansTheCommentHeader() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let unselected = brightnessColumn(of: grid.headerView, atX: 300)

        grid.headerCell.isColumnSelected = true
        grid.headerView.needsDisplay = true
        let selected = brightnessColumn(of: grid.headerView, atX: 300)

        #expect(!unselected.isEmpty)
        #expect(unselected.count == selected.count)
        let repainted = zip(unselected, selected).filter { abs($0 - $1) > 0.02 }.count
        #expect(repainted >= unselected.count - 4)
    }

    @Test("A sorted column keeps its only horizontal rule along the bottom edge")
    func sortedCommentHeaderRuleSitsAlongBottomEdge() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        grid.headerView.applySortState(sortState(column: 0), schema: grid.schema)
        grid.headerView.needsDisplay = true

        let offsets = ruleOffsets(in: grid.headerView)

        #expect(grid.headerCell.sortDirection == .ascending)
        #expect(!offsets.isEmpty)
        #expect(offsets.allSatisfy { isAlongBottomEdge($0, of: grid.headerView) })
    }

    @Test("Sorting a column leaves every column divider where it was")
    func sortingDoesNotMoveColumnDividers() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit", columns: ["code", "amount"])
        let leadingEdge = grid.headerView.headerRect(ofColumn: 1).minX
        let unsorted = brightnessColumn(of: grid.headerView, atX: leadingEdge)

        grid.headerView.applySortState(sortState(column: 1), schema: grid.schema)
        grid.headerView.needsDisplay = true
        let sorted = brightnessColumn(of: grid.headerView, atX: leadingEdge)

        #expect(!unsorted.isEmpty)
        #expect(unsorted == sorted)
    }

    @Test("Sorting never hands the column to AppKit's own header highlight")
    func sortingDoesNotUseTheAppKitColumnHighlight() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit", columns: ["code", "amount"])
        grid.headerView.applySortState(sortState(column: 1), schema: grid.schema)

        #expect(grid.tableView.highlightedTableColumn == nil)
    }

    @Test("Applying a sort state publishes it through the table's sort descriptors")
    func sortStatePublishesSortDescriptors() {
        let grid = makeGrid(comment: nil, columns: ["code", "amount"])

        grid.headerView.applySortState(sortState(column: 1, direction: .descending), schema: grid.schema)
        #expect(grid.tableView.sortDescriptors.count == 1)
        #expect(grid.tableView.sortDescriptors.first?.key == "amount")
        #expect(grid.tableView.sortDescriptors.first?.ascending == false)

        grid.headerView.applySortState(SortState(), schema: grid.schema)
        #expect(grid.tableView.sortDescriptors.isEmpty)
    }
}
