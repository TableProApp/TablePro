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

        let copyItem = NSMenuItem(title: String(localized: "Copy Column Name"), action: #selector(copyColumnName(_:)), keyEquivalent: "")
        copyItem.representedObject = baseName
        copyItem.target = self
        menu.addItem(copyItem)

        let filterItem = NSMenuItem(title: String(localized: "Filter with column"), action: #selector(filterWithColumn(_:)), keyEquivalent: "")
        filterItem.representedObject = baseName
        filterItem.target = self
        menu.addItem(filterItem)

        menu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: String(localized: "Hide Column"), action: #selector(hideColumn(_:)), keyEquivalent: "")
        hideItem.representedObject = baseName
        hideItem.target = self
        menu.addItem(hideItem)
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
}
