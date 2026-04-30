//
//  DataGridBooleanCellView.swift
//  TablePro
//

import AppKit

final class DataGridBooleanCellView: DataGridChevronCellView {
    override class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dataCell.boolean")
    }
}
