//
//  DataGridCellAccessoryDelegate.swift
//  TablePro
//

import Foundation

@MainActor
protocol DataGridCellAccessoryDelegate: AnyObject {
    func dataGridCellDidClickFKArrow(row: Int, columnIndex: Int)
    func dataGridCellDidClickChevron(row: Int, columnIndex: Int)
}
