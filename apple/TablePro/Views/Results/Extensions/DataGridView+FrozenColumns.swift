//
//  DataGridView+FrozenColumns.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func pinnedBand() -> DataGridPinnedBand {
        guard let tableView, let clipView = tableView.enclosingScrollView?.contentView else { return .none }
        let gutterWidth = DataGridRowGutterView.width(of: tableView)
        let offset = clipView.bounds.minX
        // Rows leave frozen cells to the band, so without a band view nothing is frozen.
        let frozen = rowGutter == nil ? IndexSet() : frozenTableColumnIndexes()
        guard let last = frozen.last else {
            return DataGridPinnedBand(gutterWidth: gutterWidth, width: gutterWidth, frozenColumns: [], offset: offset)
        }
        return DataGridPinnedBand.resolve(
            gutterWidth: gutterWidth,
            frozenColumns: frozen,
            frozenTrailingEdge: tableView.rect(ofColumn: last).maxX,
            viewportWidth: clipView.bounds.width,
            offset: offset
        )
    }

    // The band only while it freezes something, so a grid with nothing frozen pays one comparison.
    func freezingBand() -> DataGridPinnedBand? {
        guard frozenColumnCount > 0 else { return nil }
        let band = pinnedBand()
        return band.isFreezing ? band : nil
    }

    private func frozenTableColumnIndexes() -> IndexSet {
        let count = min(frozenColumnCount, presentedColumnCount)
        guard count > 0 else { return [] }
        var indexes = IndexSet()
        for position in 0..<count {
            guard let index = tableColumnIndex(forDisplayPosition: position) else { continue }
            indexes.insert(index)
        }
        return indexes
    }

    func displayedRect(ofColumn tableColumnIndex: Int) -> NSRect {
        guard let tableView else { return .zero }
        let rect = tableView.rect(ofColumn: tableColumnIndex)
        return freezingBand()?.displayed(rect, ofColumn: tableColumnIndex) ?? rect
    }

    func cellRect(row: Int, tableColumnIndex: Int) -> NSRect {
        guard let tableView else { return .zero }
        return tableView.rect(ofRow: row).intersection(displayedRect(ofColumn: tableColumnIndex))
    }

    func canFreezeColumns(throughDisplayPosition position: Int) -> Bool {
        guard let tableView,
              let clipView = tableView.enclosingScrollView?.contentView,
              let index = tableColumnIndex(forDisplayPosition: position) else { return false }
        return DataGridPinnedBand.fits(width: tableView.rect(ofColumn: index).maxX, viewportWidth: clipView.bounds.width)
    }

    func freezeColumns(throughDisplayPosition position: Int) {
        guard position >= 0 else { return }
        setFrozenColumnCount(position + 1)
    }

    func unfreezeColumns() {
        setFrozenColumnCount(0)
    }

    private func setFrozenColumnCount(_ count: Int) {
        guard count != frozenColumnCount else { return }
        frozenColumnCount = count
        hasUnpersistedColumnLayoutChanges = true
        persistColumnLayoutToStorage()
    }

    func frozenColumnsDidChange() {
        columnGeometryDidChange()
        tableView?.headerView?.needsDisplay = true
    }

    // A clip resize can move the band across the fit limit with no column change at all.
    func pinnedBandLayoutDidChange() {
        redrawVisibleCells()
        tableView?.headerView?.needsDisplay = true
        selectionController.overlay?.needsDisplay = true
    }

    // Rows draw no frozen cell while the band holds them, so a row repaint has to reach the band.
    func pinnedBandNeedsDisplay(rowRect rect: NSRect, row: Int) {
        guard let tableView, frozenColumnCount > 0, row >= 0, row < tableView.numberOfRows else { return }
        pinnedBandNeedsDisplay(tableRect: rect.offsetBy(dx: 0, dy: tableView.rect(ofRow: row).minY))
    }

    func pinnedBandNeedsDisplay(tableRect rect: NSRect) {
        guard let tableView, let rowGutter, let band = freezingBand() else { return }
        let minX = max(rect.minX, 0)
        let maxX = min(rect.maxX, band.width)
        guard maxX > minX else { return }
        let inBand = rowGutter.convert(NSRect(x: 0, y: rect.minY, width: 1, height: rect.height), from: tableView)
        rowGutter.setNeedsDisplay(NSRect(x: minX, y: inBand.minY, width: maxX - minX, height: inBand.height))
    }
}
