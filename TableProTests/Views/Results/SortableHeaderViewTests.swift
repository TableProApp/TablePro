//
//  SortableHeaderViewTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("SortableHeaderView comment height")
@MainActor
struct SortableHeaderViewTests {
    private struct Grid {
        let scrollView: NSScrollView
        let tableView: NSTableView
        let headerView: SortableHeaderView

        var headerClipHeight: CGFloat? {
            scrollView.subviews
                .compactMap { $0 as? NSClipView }
                .first { $0 !== scrollView.contentView }?
                .frame.height
        }
    }

    private func makeGrid() -> Grid {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("id")))
        let headerView = SortableHeaderView(frame: tableView.headerView?.frame ?? .zero)
        tableView.headerView = headerView
        scrollView.documentView = tableView
        scrollView.layoutSubtreeIfNeeded()
        return Grid(scrollView: scrollView, tableView: tableView, headerView: headerView)
    }

    @Test("Showing comments grows the scroll view's header area, not just the header frame")
    func showingCommentsGrowsHeaderClip() {
        let grid = makeGrid()
        let naturalHeight = grid.headerView.frame.height

        grid.headerView.showsComments = true

        #expect(grid.headerView.commentHeaderHeight > naturalHeight)
        #expect(grid.headerView.frame.height == grid.headerView.commentHeaderHeight)
        #expect(grid.headerClipHeight == grid.headerView.commentHeaderHeight)
    }

    @Test("Hiding comments restores the platform header height")
    func hidingCommentsRestoresNaturalHeight() {
        let grid = makeGrid()
        let naturalHeight = grid.headerView.frame.height

        grid.headerView.showsComments = true
        grid.headerView.showsComments = false

        #expect(grid.headerView.frame.height == naturalHeight)
        #expect(grid.headerClipHeight == naturalHeight)
    }

    @Test("The comment header reserves room for the comment line under the column name")
    func commentHeaderHeightFitsCommentLine() {
        let grid = makeGrid()
        let naturalHeight = grid.headerView.frame.height

        #expect(grid.headerView.commentHeaderHeight == naturalHeight + SortableHeaderCell.commentLineHeight)
    }

    @Test("Resizing and reloading the grid keeps the grown header")
    func laterLayoutKeepsGrownHeader() {
        let grid = makeGrid()
        grid.headerView.showsComments = true

        grid.scrollView.setFrameSize(NSSize(width: 320, height: 240))
        grid.scrollView.tile()
        grid.tableView.reloadData()
        grid.scrollView.layoutSubtreeIfNeeded()

        #expect(grid.headerView.frame.height == grid.headerView.commentHeaderHeight)
        #expect(grid.headerClipHeight == grid.headerView.commentHeaderHeight)
    }
}
