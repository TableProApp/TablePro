//
//  DataGridDateCellView.swift
//  TablePro
//

import AppKit

final class DataGridDateCellView: DataGridChevronCellView {
    override class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dataCell.date")
    }
}
