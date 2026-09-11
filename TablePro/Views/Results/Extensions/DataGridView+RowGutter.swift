//
//  DataGridView+RowGutter.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    /// The single way to reach a column, for Find, cell navigation and the inline editor alike.
    ///
    /// AppKit aligns a column left of the viewport flush with the clip view's leading edge, which is
    /// where the pinned row gutter sits, so the column it just scrolled to would arrive underneath
    /// it. The correction is one-sided: a column already clear of the gutter must produce no scroll
    /// at all, or every arrow keypress fights AppKit and the viewport drifts.
    ///
    /// The correction scrolls through `scroll(_:)`, which moves the header with the rows. Scrolling
    /// the clip view and reflecting it leaves the header clip where it was, measured on macOS 27, so
    /// every heading sat as far off its column as the correction had moved.
    func scrollColumnToVisible(tableColumnIndex index: Int) {
        guard let tableView, index >= 0, index < tableView.numberOfColumns else { return }
        tableView.scrollColumnToVisible(index)
        guard let clipView = tableView.enclosingScrollView?.contentView else { return }
        let gutterWidth = DataGridRowGutterView.width(of: tableView)
        guard gutterWidth > 0 else { return }
        let columnRect = tableView.rect(ofColumn: index)
        guard columnRect.width > 0 else { return }
        let hidden = clipView.bounds.origin.x + gutterWidth - columnRect.minX
        guard hidden > 0 else { return }
        tableView.scroll(NSPoint(x: clipView.bounds.origin.x - hidden, y: clipView.bounds.origin.y))
    }

    /// Re-reads the pinned gutter's geometry from the column it mirrors. The width moves when the
    /// row count crosses a digit boundary, when the page offset grows and when the Data Grid Font
    /// changes; the height moves with the row count.
    func synchronizeRowGutter() {
        rowGutter?.synchronizeGeometry()
    }

    func repaintRowGutter() {
        rowGutter?.needsDisplay = true
    }
}
