//
//  DataGridView+Columns.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

private let gridPerfLog = Logger(subsystem: "com.TablePro", category: "GridPerf")

@MainActor
internal enum ViewForStats {
    static var count: Int = 0
    static var totalMs: Double = 0
    static var firstCallTime: CFAbsoluteTime = 0
    static var lastReportedCount: Int = 0

    static var sectionA_makeView_ms: Double = 0
    static var sectionB_buttons_ms: Double = 0
    static var sectionC_textContent_ms: Double = 0
    static var sectionD_visualState_ms: Double = 0
    static var sectionE_accessibility_ms: Double = 0

    static func record(_ ms: Double) {
        if count == 0 { firstCallTime = CFAbsoluteTimeGetCurrent() }
        count += 1
        totalMs += ms
    }

    static func recordSection(a: Double = 0, b: Double = 0, c: Double = 0, d: Double = 0, e: Double = 0) {
        sectionA_makeView_ms += a
        sectionB_buttons_ms += b
        sectionC_textContent_ms += c
        sectionD_visualState_ms += d
        sectionE_accessibility_ms += e
    }

    static func flushIfQuiet() {
        guard count > lastReportedCount else { return }
        let delta = count - lastReportedCount
        gridPerfLog.notice("[grid-perf] viewFor batch: \(delta) calls, total \(totalMs, format: .fixed(precision: 2)) ms since last report")
        gridPerfLog.notice("[grid-perf]   sectionA makeView/reuse: \(sectionA_makeView_ms, format: .fixed(precision: 2)) ms")
        gridPerfLog.notice("[grid-perf]   sectionB FK/chevron buttons: \(sectionB_buttons_ms, format: .fixed(precision: 2)) ms")
        gridPerfLog.notice("[grid-perf]   sectionC configureTextContent: \(sectionC_textContent_ms, format: .fixed(precision: 2)) ms")
        gridPerfLog.notice("[grid-perf]   sectionD CATransaction+bg+focus: \(sectionD_visualState_ms, format: .fixed(precision: 2)) ms")
        gridPerfLog.notice("[grid-perf]   sectionE accessibility labels: \(sectionE_accessibility_ms, format: .fixed(precision: 2)) ms")
        lastReportedCount = count
        totalMs = 0
        sectionA_makeView_ms = 0
        sectionB_buttons_ms = 0
        sectionC_textContent_ms = 0
        sectionD_visualState_ms = 0
        sectionE_accessibility_ms = 0
    }
}

extension TableViewCoordinator {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let __tCell = CFAbsoluteTimeGetCurrent()
        guard let column = tableColumn else {
            let __view: NSView? = nil
            ViewForStats.record((CFAbsoluteTimeGetCurrent() - __tCell) * 1000)
            return __view
        }

        let tableRows = tableRowsProvider()
        let displayCount = sortedIDs?.count ?? tableRows.count

        if column.identifier == ColumnIdentitySchema.rowNumberIdentifier {
            let __view: NSView? = cellFactory.makeRowNumberCell(
                tableView: tableView,
                row: row,
                cachedRowCount: displayCount,
                visualState: visualState(for: row)
            )
            ViewForStats.record((CFAbsoluteTimeGetCurrent() - __tCell) * 1000)
            return __view
        }

        guard let columnIndex = dataColumnIndex(from: column.identifier) else {
            let __view: NSView? = nil
            ViewForStats.record((CFAbsoluteTimeGetCurrent() - __tCell) * 1000)
            return __view
        }

        guard row >= 0 && row < displayCount,
              columnIndex >= 0 && columnIndex < cachedColumnCount else {
            let __view: NSView? = nil
            ViewForStats.record((CFAbsoluteTimeGetCurrent() - __tCell) * 1000)
            return __view
        }

        guard let displayRow = displayRow(at: row),
              columnIndex < displayRow.values.count else {
            let __view: NSView? = nil
            ViewForStats.record((CFAbsoluteTimeGetCurrent() - __tCell) * 1000)
            return __view
        }
        let rawValue = displayRow.values[columnIndex]
        let columnType = columnIndex < tableRows.columnTypes.count
            ? tableRows.columnTypes[columnIndex]
            : nil
        let formattedValue = displayValue(
            forID: displayRow.id,
            column: columnIndex,
            rawValue: rawValue,
            columnType: columnType
        )
        let state = visualState(for: row)

        let tableColumnIndex = DataGridView.tableColumnIndex(for: columnIndex)
        let isFocused: Bool = {
            guard let keyTableView = tableView as? KeyHandlingTableView,
                  keyTableView.focusedRow == row,
                  keyTableView.focusedColumn == tableColumnIndex else { return false }
            return true
        }()

        let isDropdown = dropdownColumns?.contains(columnIndex) == true
        let isTypePicker = typePickerColumns?.contains(columnIndex) == true

        let isEnumOrSet = enumOrSetColumns.contains(columnIndex)
        let isFKColumn = fkColumns.contains(columnIndex)

        let hasSpecialEditor: Bool = {
            guard columnIndex < tableRows.columnTypes.count else { return false }
            let ct = tableRows.columnTypes[columnIndex]
            return ct.isBooleanType || ct.isDateType || ct.isJsonType || ct.isBlobType
        }()

        let __view: NSView? = cellFactory.makeDataCell(
            tableView: tableView,
            row: row,
            columnIndex: columnIndex,
            displayValue: formattedValue,
            rawValue: rawValue,
            visualState: state,
            isEditable: isEditable && !state.isDeleted,
            isLargeDataset: isLargeDataset,
            isFocused: isFocused,
            isDropdown: isEditable && (isDropdown || isTypePicker || isEnumOrSet || hasSpecialEditor),
            isFKColumn: isFKColumn && !isDropdown && !(typePickerColumns?.contains(columnIndex) == true),
            fkArrowTarget: self,
            fkArrowAction: #selector(handleFKArrowClick(_:)),
            chevronTarget: self,
            chevronAction: #selector(handleChevronClick(_:)),
            delegate: self
        )
        ViewForStats.record((CFAbsoluteTimeGetCurrent() - __tCell) * 1000)
        return __view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let delegateRowView = delegate?.dataGridRowView(for: tableView, row: row, coordinator: self) {
            return delegateRowView
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? TableRowViewWithMenu)
            ?? TableRowViewWithMenu()
        rowView.identifier = Self.rowViewIdentifier
        rowView.coordinator = self
        rowView.rowIndex = row
        return rowView
    }
}
