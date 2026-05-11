//
//  DataGridUpdateSnapshot.swift
//  TablePro
//

import AppKit
import Foundation

/// Captures the inputs `DataGridView.updateNSView(_:context:)` cares about so the
/// coordinator can skip the heavy reconciliation pipeline when SwiftUI re-evaluates
/// the parent view without any data, configuration, or layout change.
@MainActor
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

/// Lightweight fingerprint for column metadata sets (FK / enum). Catches the common
/// cases where columns are added, removed, or have their metadata replaced. Identical
/// fingerprints with the same schema mean the kind sets do not need to be rebuilt.
struct ColumnMetadataFingerprint: Equatable {
    let columnsCount: Int
    let columnTypesCount: Int
    let foreignKeyKeysCount: Int
    let enumValuesKeysCount: Int

    static let empty = ColumnMetadataFingerprint(
        columnsCount: 0,
        columnTypesCount: 0,
        foreignKeyKeysCount: 0,
        enumValuesKeysCount: 0
    )
}
