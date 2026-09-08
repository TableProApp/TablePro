//
//  DataGridView+ColumnDisplayOrder.swift
//  TablePro
//

import AppKit

/// The translation between the two column spaces the grid keeps, and the only place either one is
/// converted into the other.
///
/// A **data index** is a schema slot: `ColumnIdentitySchema` numbers the result's columns
/// `dataColumn-0…n` in the order the result produced them, and that numbering never moves. It is
/// what indexes `TableRows.columns` and `Row.values`, so every read and write of a value speaks it.
///
/// A **display position** is where a column sits on screen: an index into the presented run, in
/// `tableColumns` order, skipping the row-number column, the pool's surplus slots and anything the
/// user hid. Reordering a column changes this and leaves the data index alone.
///
/// `GridCoord.displayColumn` is the second of these. It has to be: a `GridRect` is a rectangle, so
/// its column axis is a `ClosedRange`, and a range over slots cannot name the block a drag actually
/// swept once the two orders differ. Building the rect in slot space made a sweep across two
/// on-screen columns select and copy a third the pointer never touched.
extension TableViewCoordinator {
    /// Display position to data index. The array's index is the position, its element the slot.
    ///
    /// With no table view there is no display order, so the two spaces coincide over the result's
    /// own columns. The count comes from the result rather than from `identitySchema`, which is
    /// empty until `rebuildColumnMetadataCache` has run and would otherwise report a grid with no
    /// columns at all.
    var presentedDataColumns: [Int] {
        if let cached = cachedPresentedDataColumns { return cached }
        /// The fallback is deliberately not cached: nothing invalidates on a table view being
        /// attached, so a map derived before there was one would outlive the state that produced it.
        guard let resolved = visibleColumnDataIndices() else {
            return Array(0..<tableRowsProvider().columns.count)
        }
        cachedPresentedDataColumns = resolved
        return resolved
    }

    var presentedColumnCount: Int { presentedDataColumns.count }

    func dataColumnIndex(atDisplayPosition position: Int) -> Int? {
        let columns = presentedDataColumns
        guard position >= 0, position < columns.count else { return nil }
        return columns[position]
    }

    func displayPosition(ofDataColumnIndex dataIndex: Int) -> Int? {
        presentedDataColumns.firstIndex(of: dataIndex)
    }

    /// The data indices a selection covers, in display order. This is the slot-space answer every
    /// consumer that reads or writes a value wants.
    func dataColumnIndices(in columns: IndexSet) -> [Int] {
        columns.compactMap { dataColumnIndex(atDisplayPosition: $0) }
    }

    /// Where a display position sits in `tableColumns`, which is what the cell cursor and every
    /// `rect(ofColumn:)` are expressed in.
    func tableColumnIndex(forDisplayPosition position: Int) -> Int? {
        guard let dataIndex = dataColumnIndex(atDisplayPosition: position) else { return nil }
        return tableColumnIndex(for: dataIndex)
    }

    func invalidatePresentedColumnCache() {
        cachedPresentedDataColumns = nil
    }
}
