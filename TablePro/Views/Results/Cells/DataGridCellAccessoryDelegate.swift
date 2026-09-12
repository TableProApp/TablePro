//
//  DataGridCellAccessoryDelegate.swift
//  TablePro
//

import Foundation

@MainActor
protocol DataGridCellAccessoryDelegate: AnyObject {
    func dataGridCellDidClickFKArrow(row: Int, columnIndex: Int, intent: ReferenceOpenIntent)
    func dataGridCellDidClickChevron(row: Int, columnIndex: Int)
    func dataGridCellDidDoubleClick(row: Int, columnIndex: Int)
}
