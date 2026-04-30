//
//  DataGridDropdownCellView.swift
//  TablePro
//

import AppKit

final class DataGridDropdownCellView: DataGridChevronCellView {
    override class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dataCell.dropdown")
    }
}
