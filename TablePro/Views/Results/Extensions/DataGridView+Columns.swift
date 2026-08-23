//
//  DataGridView+Columns.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

extension TableViewCoordinator {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        autoreleasepool { viewForCell(in: tableView, column: tableColumn, row: row) }
    }

    /// Only the row-number column still mounts a view.
    ///
    /// A data cell is drawn by its row instead. `NSTableView` builds one cell view per column per
    /// prepared row whatever the viewport shows, so a 500-column result carried 12,500 views and
    /// 837MB of them; returning nil here leaves 26 views in the whole table and 3.9MB (#2381).
    private func viewForCell(in tableView: NSTableView, column tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        guard column.identifier == ColumnIdentitySchema.rowNumberIdentifier else { return nil }

        let tableRows = tableRowsProvider()
        return cellRegistry.makeRowNumberCell(
            in: tableView,
            row: row,
            pageOffset: paginationOffsetProvider(),
            cachedRowCount: displayIDs?.count ?? tableRows.count,
            visualState: visualState(for: row)
        )
    }

    /// What one data cell looks like, for the row that draws it.
    ///
    /// - Parameters:
    ///   - onEmphasizedSelection: whether the row is drawn as selected, which changes the text
    ///     colour and stands the modified tint down.
    func cellAppearance(
        row: Int,
        columnIndex: Int,
        onEmphasizedSelection: Bool
    ) -> DataGridCellAppearance? {
        let tableRows = tableRowsProvider()
        let displayCount = displayIDs?.count ?? tableRows.count
        guard row >= 0, row < displayCount,
              columnIndex >= 0, columnIndex < cachedColumnCount,
              let displayRow = displayRow(at: row, in: tableRows),
              columnIndex < displayRow.values.count else { return nil }

        let rawValue = displayRow.values[columnIndex]
        let columnType = columnIndex < tableRows.columnTypes.count ? tableRows.columnTypes[columnIndex] : nil
        let formattedValue = displayValue(
            forID: displayRow.id,
            column: columnIndex,
            rawValue: rawValue,
            columnType: columnType
        )

        let isFocused: Bool = {
            guard let keyTableView = tableView as? KeyHandlingTableView,
                  keyTableView.focusedRow == row,
                  let position = tableColumnIndex(for: columnIndex),
                  keyTableView.focusedColumn == position else { return false }
            return true
        }()

        return DataGridCellAppearance.resolve(
            kind: columnPresentation(for: columnIndex, in: tableRows).kind,
            content: DataGridCellContent(
                displayText: formattedValue ?? "",
                rawValue: rawValue.asText,
                placeholder: DataGridCellContent.placeholder(for: rawValue)
            ),
            state: DataGridCellState(
                visualState: visualState(for: row),
                isFocused: isFocused,
                isEditable: isEditable,
                isLargeDataset: isLargeDataset,
                isCurrentFindMatch: currentFindMatch == FindMatch(displayRow: row, columnIndex: columnIndex),
                row: row,
                columnIndex: columnIndex
            ),
            palette: cellRegistry.palette,
            nullDisplayString: cellRegistry.nullDisplayString,
            onEmphasizedSelection: onEmphasizedSelection,
            hasOverlay: overlayCell == CellPosition(row: row, column: columnIndex)
        )
    }

    /// What VoiceOver reads for one cell. A placeholder announces itself by name rather than as the
    /// empty string a sighted reader sees as an italic marker.
    func accessibilityText(row: Int, columnIndex: Int) -> String? {
        let tableRows = tableRowsProvider()
        guard let displayRow = displayRow(at: row, in: tableRows),
              columnIndex < displayRow.values.count else { return nil }
        let rawValue = displayRow.values[columnIndex]
        let columnType = columnIndex < tableRows.columnTypes.count ? tableRows.columnTypes[columnIndex] : nil
        let text = displayValue(
            forID: displayRow.id,
            column: columnIndex,
            rawValue: rawValue,
            columnType: columnType
        ) ?? ""
        guard text.isEmpty else { return text }

        switch DataGridCellContent.placeholder(for: rawValue) {
        case .null: return String(localized: "NULL")
        case .empty: return String(localized: "Empty")
        case .defaultMarker: return String(localized: "DEFAULT")
        case .none: return text
        }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let tableColumn else { return nil }
        guard tableColumn.identifier != ColumnIdentitySchema.rowNumberIdentifier else { return nil }
        guard let columnIndex = dataColumnIndex(from: tableColumn.identifier) else { return nil }
        guard let displayRow = displayRow(at: row) else { return nil }
        guard columnIndex < displayRow.values.count else { return nil }
        return displayRow.values[columnIndex].asText
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let delegateRowView = delegate?.dataGridRowView(for: tableView, row: row, coordinator: self) {
            // Delegate-provided row views (e.g. StructureRowViewWithMenu) must still
            // pick up the deleted/inserted/modified tint. Apply the visual state if
            // the row view subclasses DataGridRowView; otherwise the delegate is
            // responsible for its own visual state.
            if let dataGridRow = delegateRowView as? DataGridRowView {
                dataGridRow.applyVisualState(visualState(for: row))
            }
            return delegateRowView
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? DataGridRowView)
            ?? DataGridRowView()
        rowView.identifier = Self.rowViewIdentifier
        rowView.coordinator = self
        rowView.rowIndex = row
        rowView.applyVisualState(visualState(for: row))
        return rowView
    }
}
