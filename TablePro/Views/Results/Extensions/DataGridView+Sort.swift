//
//  DataGridView+Sort.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    // MARK: - Native Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncingSortDescriptors else { return }

        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key,
              key.hasPrefix("col_"),
              let columnIndex = Int(key.dropFirst(4)),
              columnIndex >= 0 && columnIndex < rowProvider.columns.count else {
            return
        }

        let isMultiSort = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        onSort?(columnIndex, sortDescriptor.ascending, isMultiSort)
    }

    // MARK: - Double-Click Column Divider Auto-Fit

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn columnIndex: Int) -> CGFloat {
        let column = tableView.tableColumns[columnIndex]
        guard column.identifier.rawValue != "__rowNumber__" else {
            return column.width
        }
        guard let dataColumnIndex = DataGridView.columnIndex(from: column.identifier) else {
            return column.width
        }

        let width = cellFactory.calculateFitToContentWidth(
            for: dataColumnIndex < rowProvider.columns.count ? rowProvider.columns[dataColumnIndex] : column.title,
            columnIndex: dataColumnIndex,
            rowProvider: rowProvider
        )
        hasUserResizedColumns = true
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
        if column.identifier.rawValue == "__rowNumber__" { return }

        // Derive base column name from stable identifier (avoids sort indicator in title)
        let baseName: String = {
            if let idx = DataGridView.columnIndex(from: column.identifier),
               idx < rowProvider.columns.count {
                return rowProvider.columns[idx]
            }
            return column.title
        }()

        if let dataColumnIndex = DataGridView.columnIndex(from: column.identifier) {
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

            menu.addItem(NSMenuItem.separator())
        }

        let copyItem = NSMenuItem(title: String(localized: "Copy Column Name"), action: #selector(copyColumnName(_:)), keyEquivalent: "")
        copyItem.representedObject = baseName
        copyItem.target = self
        menu.addItem(copyItem)

        let filterItem = NSMenuItem(title: String(localized: "Filter with column"), action: #selector(filterWithColumn(_:)), keyEquivalent: "")
        filterItem.representedObject = baseName
        filterItem.target = self
        menu.addItem(filterItem)

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

        if onShowAllColumns != nil,
           tableView.tableColumns.contains(where: { $0.isHidden && $0.identifier.rawValue != "__rowNumber__" }) {
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
        onSort?(columnIndex, true, false)
    }

    @objc func sortDescending(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        onSort?(columnIndex, false, false)
    }

    @objc func showAllColumns() {
        onShowAllColumns?()
    }

    @objc func copyColumnName(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        ClipboardService.shared.writeText(columnName)
    }

    @objc func filterWithColumn(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        onFilterColumn?(columnName)
    }

    @objc func hideColumn(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        onHideColumn?(columnName)
    }

    @objc func sizeColumnToFit(_ sender: NSMenuItem) {
        guard let tableView,
              let columnIndex = sender.representedObject as? Int,
              columnIndex >= 0 && columnIndex < tableView.tableColumns.count else { return }

        let column = tableView.tableColumns[columnIndex]
        guard let dataColumnIndex = DataGridView.columnIndex(from: column.identifier) else { return }

        let width = cellFactory.calculateFitToContentWidth(
            for: dataColumnIndex < rowProvider.columns.count ? rowProvider.columns[dataColumnIndex] : column.title,
            columnIndex: dataColumnIndex,
            rowProvider: rowProvider
        )
        column.width = width
        hasUserResizedColumns = true
    }

    @objc func sizeAllColumnsToFit(_ sender: NSMenuItem) {
        guard let tableView else { return }

        for column in tableView.tableColumns {
            guard column.identifier.rawValue != "__rowNumber__",
                  let dataColumnIndex = DataGridView.columnIndex(from: column.identifier) else { continue }

            let width = cellFactory.calculateFitToContentWidth(
                for: dataColumnIndex < rowProvider.columns.count ? rowProvider.columns[dataColumnIndex] : column.title,
                columnIndex: dataColumnIndex,
                rowProvider: rowProvider
            )
            column.width = width
        }
        hasUserResizedColumns = true
    }
}
