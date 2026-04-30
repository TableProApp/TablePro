//
//  DataGridTextCellView.swift
//  TablePro
//

import AppKit

final class DataGridTextCellView: DataGridBaseCellView {
    override class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dataCell.text")
    }
}
