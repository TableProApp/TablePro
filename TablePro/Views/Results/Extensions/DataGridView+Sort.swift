//
//  DataGridView+Sort.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    // MARK: - Double-Click Column Divider Auto-Fit

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn columnIndex: Int) -> CGFloat {
        let column = tableView.tableColumns[columnIndex]
        guard column.identifier != ColumnIdentitySchema.rowNumberIdentifier else {
            return column.width
        }
        guard let dataColumnIndex = dataColumnIndex(from: column.identifier) else {
            return column.width
        }

        let tableRows = tableRowsProvider()
        let width = cellFactory.calculateFitToContentWidth(
            for: dataColumnIndex < tableRows.columns.count ? tableRows.columns[dataColumnIndex] : column.title,
            columnIndex: dataColumnIndex,
            tableRows: tableRows
        )
        return width
    }

    // MARK: - NSMenuDelegate (Header Context Menu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let tableView = tableView,
              let headerView = tableView.headerView,
              let window = tableView.window else { return }

        let mouseLocation = window.mouseLocationOutsideOfEventStream
        let pointInHeader = headerView.convert(mouseLocation, from: nil)
        let columnIndex = headerView.column(at: pointInHeader)

        guard columnIndex >= 0 && columnIndex < tableView.tableColumns.count else { return }

        let column = tableView.tableColumns[columnIndex]
        if column.identifier == ColumnIdentitySchema.rowNumberIdentifier { return }

        let tableRows = tableRowsProvider()
        let baseName: String = {
            if let idx = dataColumnIndex(from: column.identifier),
               idx < tableRows.columns.count {
                return tableRows.columns[idx]
            }
            return column.title
        }()

        if let dataColumnIndex = dataColumnIndex(from: column.identifier) {
            let sortAscItem = NSMenuItem(
                title: String(localized: "Sort Ascending"),
                action: #selector(sortAscending(_:)),
                keyEquivalent: ""
            )
            sortAscItem.representedObject = dataColumnIndex
            sortAscItem.target = self
            menu.addItem(sortAscItem)

            let sortDescItem = NSMenuItem(
                title: String(localized: "Sort Descending"),
                action: #selector(sortDescending(_:)),
                keyEquivalent: ""
            )
            sortDescItem.representedObject = dataColumnIndex
            sortDescItem.target = self
            menu.addItem(sortDescItem)

            if currentSortState.isSorting {
                let clearSortItem = NSMenuItem(
                    title: String(localized: "Don't Sort"),
                    action: #selector(clearSortAction),
                    keyEquivalent: ""
                )
                clearSortItem.target = self
                menu.addItem(clearSortItem)
            }

            menu.addItem(NSMenuItem.separator())
        }

        let copyItem = NSMenuItem(title: String(localized: "Copy Column Name"), action: #selector(copyColumnName(_:)), keyEquivalent: "")
        copyItem.representedObject = baseName
        copyItem.target = self
        menu.addItem(copyItem)

        if let dataColumnIndex = dataColumnIndex(from: column.identifier) {
            let copyValuesItem = NSMenuItem(
                title: String(localized: "Copy Column Values"),
                action: #selector(copyColumnValues(_:)),
                keyEquivalent: ""
            )
            copyValuesItem.representedObject = dataColumnIndex
            copyValuesItem.target = self
            menu.addItem(copyValuesItem)
        }

        if let dataColumnIndex = dataColumnIndex(from: column.identifier),
           isEditable,
           cachedRowCount > 0,
           !primaryKeyColumns.contains(baseName) {
            let fillItem = NSMenuItem(
                title: String(localized: "Fill Column…"),
                action: #selector(fillColumn(_:)),
                keyEquivalent: ""
            )
            fillItem.representedObject = dataColumnIndex
            fillItem.target = self
            menu.addItem(fillItem)
        }

        let filterItem = NSMenuItem(title: String(localized: "Filter with column"), action: #selector(filterWithColumn(_:)), keyEquivalent: "")
        filterItem.representedObject = baseName
        filterItem.target = self
        menu.addItem(filterItem)

        if let dataColumnIndex = dataColumnIndex(from: column.identifier) {
            let filterValuesItem = NSMenuItem(
                title: String(localized: "Filter Values…"),
                action: #selector(filterColumnValues(_:)),
                keyEquivalent: ""
            )
            filterValuesItem.representedObject = dataColumnIndex
            filterValuesItem.target = self
            menu.addItem(filterValuesItem)

            if valueFilterState.isActive(column: dataColumnIndex) {
                let clearColumnItem = NSMenuItem(
                    title: String(localized: "Clear Value Filter"),
                    action: #selector(clearColumnValueFilter(_:)),
                    keyEquivalent: ""
                )
                clearColumnItem.representedObject = dataColumnIndex
                clearColumnItem.target = self
                menu.addItem(clearColumnItem)
            }
        }

        if valueFilterState.isActive {
            let clearAllItem = NSMenuItem(
                title: String(localized: "Clear All Value Filters"),
                action: #selector(clearAllValueFiltersAction),
                keyEquivalent: ""
            )
            clearAllItem.target = self
            menu.addItem(clearAllItem)
        }

        if let dataColumnIndex = dataColumnIndex(from: column.identifier) {
            let columnType = dataColumnIndex < tableRows.columnTypes.count ? tableRows.columnTypes[dataColumnIndex] : nil
            let applicableFormats = ValueDisplayFormat.applicableFormats(for: columnType)
            if applicableFormats.count > 1 {
                let displaySubmenu = NSMenu()
                let currentFormat = ValueDisplayFormatService.shared.effectiveFormat(
                    columnName: baseName,
                    connectionId: connectionId,
                    tableName: tableName
                )
                for format in applicableFormats {
                    let item = NSMenuItem(
                        title: format.displayName,
                        action: #selector(setDisplayFormat(_:)),
                        keyEquivalent: ""
                    )
                    item.representedObject = DisplayFormatMenuItem(
                        columnName: baseName,
                        columnIndex: dataColumnIndex,
                        format: format
                    )
                    item.target = self
                    item.state = (format == currentFormat) ? .on : .off
                    displaySubmenu.addItem(item)
                }
                let displayItem = NSMenuItem(title: String(localized: "Display As"), action: nil, keyEquivalent: "")
                displayItem.submenu = displaySubmenu
                menu.addItem(displayItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let sizeToFitItem = NSMenuItem(title: String(localized: "Size to Fit"), action: #selector(sizeColumnToFit(_:)), keyEquivalent: "")
        sizeToFitItem.representedObject = columnIndex
        sizeToFitItem.target = self
        menu.addItem(sizeToFitItem)

        let sizeAllItem = NSMenuItem(title: String(localized: "Size All Columns to Fit"), action: #selector(sizeAllColumnsToFit(_:)), keyEquivalent: "")
        sizeAllItem.target = self
        menu.addItem(sizeAllItem)

        menu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: String(localized: "Hide Column"), action: #selector(hideColumn(_:)), keyEquivalent: "")
        hideItem.representedObject = baseName
        hideItem.target = self
        menu.addItem(hideItem)

        if delegate != nil,
           tableView.tableColumns.contains(where: { $0.isHidden && $0.identifier != ColumnIdentitySchema.rowNumberIdentifier }) {
            let showAllItem = NSMenuItem(
                title: String(localized: "Show All Columns"),
                action: #selector(showAllColumns),
                keyEquivalent: ""
            )
            showAllItem.target = self
            menu.addItem(showAllItem)
        }
    }

    @objc func sortAscending(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        var state = SortState()
        state.columns = [SortColumn(columnIndex: columnIndex, direction: .ascending)]
        currentSortState = state
        updateSortIndicatorsFromCurrentState()
        delegate?.dataGridSortStateChanged(state)
    }

    @objc func sortDescending(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        var state = SortState()
        state.columns = [SortColumn(columnIndex: columnIndex, direction: .descending)]
        currentSortState = state
        updateSortIndicatorsFromCurrentState()
        delegate?.dataGridSortStateChanged(state)
    }

    @objc func showAllColumns() {
        delegate?.dataGridShowAllColumns()
    }

    @objc func clearSortAction() {
        currentSortState = SortState()
        updateSortIndicatorsFromCurrentState()
        delegate?.dataGridSortStateChanged(SortState())
    }

    private func updateSortIndicatorsFromCurrentState() {
        guard let header = tableView?.headerView as? SortableHeaderView else { return }
        header.updateSortIndicators(state: currentSortState, schema: identitySchema)
    }

    @objc func copyColumnName(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        ClipboardService.shared.writeText(columnName)
    }

    @objc func copyColumnValues(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        copyColumnValues(columnIndex: columnIndex)
    }

    @objc func filterWithColumn(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        delegate?.dataGridFilterColumn(columnName)
    }

    @objc func filterColumnValues(_ sender: NSMenuItem) {
        guard let dataIndex = sender.representedObject as? Int,
              let tableView,
              let header = tableView.headerView as? SortableHeaderView,
              let columnIndex = tableColumnIndex(for: dataIndex),
              let cell = tableView.tableColumns[columnIndex].headerCell as? SortableHeaderCell else { return }
        let anchor = cell.funnelRect(forBounds: header.headerRect(ofColumn: columnIndex))
        presentValueFilterPopover(forColumn: dataIndex, anchor: anchor, in: header)
    }

    @objc func clearColumnValueFilter(_ sender: NSMenuItem) {
        guard let dataIndex = sender.representedObject as? Int else { return }
        applyValueFilter(nil, columnName: "", forColumn: dataIndex)
    }

    @objc func clearAllValueFiltersAction() {
        clearAllValueFilters()
    }

    @objc func hideColumn(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        delegate?.dataGridHideColumn(columnName)
    }

    @objc func sizeColumnToFit(_ sender: NSMenuItem) {
        guard let tableView,
              let columnIndex = sender.representedObject as? Int,
              columnIndex >= 0 && columnIndex < tableView.tableColumns.count else { return }

        let column = tableView.tableColumns[columnIndex]
        guard let dataColumnIndex = dataColumnIndex(from: column.identifier) else { return }

        let tableRows = tableRowsProvider()
        let width = cellFactory.calculateFitToContentWidth(
            for: dataColumnIndex < tableRows.columns.count ? tableRows.columns[dataColumnIndex] : column.title,
            columnIndex: dataColumnIndex,
            tableRows: tableRows
        )
        column.width = width
    }

    @objc func sizeAllColumnsToFit(_ sender: NSMenuItem) {
        guard let tableView else { return }

        let tableRows = tableRowsProvider()
        for column in tableView.tableColumns {
            guard column.identifier != ColumnIdentitySchema.rowNumberIdentifier,
                  let dataColumnIndex = dataColumnIndex(from: column.identifier) else { continue }

            let width = cellFactory.calculateFitToContentWidth(
                for: dataColumnIndex < tableRows.columns.count ? tableRows.columns[dataColumnIndex] : column.title,
                columnIndex: dataColumnIndex,
                tableRows: tableRows
            )
            column.width = width
        }
    }

    @objc func setDisplayFormat(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? DisplayFormatMenuItem else { return }

        let formatToStore: ValueDisplayFormat? = (info.format == .raw) ? nil : info.format

        if let connId = connectionId, let table = tableName {
            ValueDisplayFormatService.shared.setOverride(
                formatToStore,
                columnName: info.columnName,
                connectionId: connId,
                tableName: table
            )
        }

        var formats = columnDisplayFormats
        while formats.count <= info.columnIndex {
            formats.append(nil)
        }
        formats[info.columnIndex] = (info.format == .raw) ? nil : info.format
        updateDisplayFormats(formats)

        guard let tableView else { return }
        let visibleRect = tableView.visibleRect
        let visibleRange = tableView.rows(in: visibleRect)
        if visibleRange.length > 0 {
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }
    }
}

/// Payload for the "Display As" context menu item
private final class DisplayFormatMenuItem {
    let columnName: String
    let columnIndex: Int
    let format: ValueDisplayFormat

    init(columnName: String, columnIndex: Int, format: ValueDisplayFormat) {
        self.columnName = columnName
        self.columnIndex = columnIndex
        self.format = format
    }
}
