//
//  DataGridJsonCellView.swift
//  TablePro
//

import AppKit

final class DataGridJsonCellView: DataGridChevronCellView {
    override class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dataCell.json")
    }
}
