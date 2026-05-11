//
//  DataGridUpdateSnapshot.swift
//  TablePro
//

import AppKit
import Foundation

/// Equatable input signature; coordinator bails the updateNSView pipeline when unchanged.
struct DataGridUpdateSnapshot: Equatable {
    let rowDisplayCount: Int
    let columnCount: Int
    let columns: [String]
    let sortedIDsCount: Int?
    let displayFormats: [ValueDisplayFormat?]
    let configuration: DataGridConfiguration
    let isEditable: Bool
    let hasMoveDelegate: Bool
    let rowHeight: CGFloat
    let alternatingRows: Bool
}
