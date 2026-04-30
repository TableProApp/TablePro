//
//  DataGridBlobCellView.swift
//  TablePro
//

import AppKit

final class DataGridBlobCellView: DataGridChevronCellView {
    override class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dataCell.blob")
    }
}
