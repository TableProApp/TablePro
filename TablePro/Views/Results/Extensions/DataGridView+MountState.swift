//
//  DataGridView+MountState.swift
//  TablePro
//
//  The viewport and selection a grid hands to an owner that outlives it, and takes back on the
//  next mount.
//
//  SwiftUI destroys `TableViewCoordinator` whenever the grid leaves the view tree, and the editor
//  mounts the grid as `.id(tab.id)`, so a tab switch and a result-mode switch both rebuild it from
//  nothing. Anything here that is not handed over first is gone.
//

import AppKit
import Foundation

extension TableViewCoordinator {
    var scrollAnchorRow: Int { pendingScrollAnchorRow ?? 0 }

    /// Records where the user was looking, so returning to this tab does not start at the first row.
    func recordScrollAnchor() {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        displayState.firstVisibleRow = max(0, visible.location)
    }

    /// `scrollRowToVisible` only guarantees visibility, so from a grid scrolled to the top it puts
    /// the anchor at the bottom of the viewport rather than back where the user left it.
    func restoreScrollAnchor() {
        guard let tableView, let row = pendingScrollAnchorRow else { return }
        pendingScrollAnchorRow = nil
        guard row > 0, row < tableView.numberOfRows else { return }
        let origin = tableView.rect(ofRow: row).origin
        let x = tableView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        tableView.scroll(NSPoint(x: x, y: origin.y))
    }

    /// Hands this grid's selection to an owner that outlives it, on the way out.
    ///
    /// Read from this grid's own table view rather than from the shared `GridSelectionState`, which
    /// by teardown time can already describe the tab being switched to. That also makes an owner
    /// check unnecessary: a data grid's table view only ever holds data-grid positions.
    ///
    /// The rows are passed alongside the cell rectangle rather than derived from it, because a cell
    /// drag pins `selectedRowIndexes` to its anchor row and only the rectangle knows the rest.
    func captureSelectionForTeardown() {
        guard let onSelectionTeardown else { return }
        let rows = tableView.map { Set($0.selectedRowIndexes) } ?? []
        onSelectionTeardown(rows, selectionController.selection)
    }
}
