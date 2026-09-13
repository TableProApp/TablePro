//
//  GridViewportResolver.swift
//  TablePro
//

import CoreGraphics
import Foundation
import TableProPluginKit

internal struct GridViewportSnapshot: Equatable {
    let firstVisiblePosition: Int
    let firstVisibleOffset: CGFloat
    let firstVisibleKey: [String: String]?

    static let top = GridViewportSnapshot(firstVisiblePosition: 0, firstVisibleOffset: 0, firstVisibleKey: nil)
}

internal struct GridViewportPlacement: Equatable {
    let firstVisibleRow: RowID?
    let firstVisibleOffset: CGFloat
    let selectedRows: [RowID]
    let revealsSelection: Bool

    static let firstRow = GridViewportPlacement(
        firstVisibleRow: nil,
        firstVisibleOffset: 0,
        selectedRows: [],
        revealsSelection: false
    )
}

internal struct GridViewportStage: Equatable {
    let bufferEpoch: Int
    let placement: GridViewportPlacement
}

internal enum GridViewportResolver {
    static let keyedRowLimit = 50_000

    static func snapshot(
        of tableRows: TableRows,
        displayIDs: [RowID]?,
        firstVisibleDisplayRow: Int,
        firstVisibleOffset: CGFloat,
        keyColumns: [String],
        isCellModified: (RowID, Int) -> Bool = { _, _ in false }
    ) -> GridViewportSnapshot {
        let isKeyed = !keyColumns.isEmpty && tableRows.count <= keyedRowLimit
        let firstVisibleKey = isKeyed
            ? DisplayRowMapping.row(forDisplay: firstVisibleDisplayRow, displayIDs: displayIDs, in: tableRows)
                .flatMap { savedKey(of: $0, in: tableRows, keyColumns: keyColumns, isCellModified: isCellModified) }
            : nil
        return GridViewportSnapshot(
            firstVisiblePosition: max(0, firstVisibleDisplayRow),
            firstVisibleOffset: max(0, firstVisibleOffset),
            firstVisibleKey: firstVisibleKey
        )
    }

    static func placement(
        for intent: GridReloadIntent,
        from snapshot: GridViewportSnapshot,
        in incoming: TableRows,
        keyColumns: [String]
    ) -> GridViewportPlacement {
        guard !incoming.rows.isEmpty else { return .firstRow }
        switch intent {
        case .firstRow:
            return .firstRow
        case .keepPlace:
            return keptPlace(from: snapshot, in: incoming, keyColumns: keyColumns)
        case .restoreRow(let anchor):
            guard let row = uniqueRow(matching: anchor, in: incoming) else { return .firstRow }
            return GridViewportPlacement(
                firstVisibleRow: nil,
                firstVisibleOffset: 0,
                selectedRows: [row],
                revealsSelection: true
            )
        }
    }

    private static func savedKey(
        of row: Row,
        in tableRows: TableRows,
        keyColumns: [String],
        isCellModified: (RowID, Int) -> Bool
    ) -> [String: String]? {
        guard !row.id.isInserted else { return nil }
        return NavigationRowAnchor.build(
            keyColumns: keyColumns,
            columns: tableRows.columns,
            values: row.values,
            isModified: { isCellModified(row.id, $0) }
        )
    }

    private static func keptPlace(
        from snapshot: GridViewportSnapshot,
        in incoming: TableRows,
        keyColumns: [String]
    ) -> GridViewportPlacement {
        guard snapshot.firstVisiblePosition > 0 || snapshot.firstVisibleOffset > 0 else { return .firstRow }

        if let firstVisibleKey = snapshot.firstVisibleKey,
           !keyColumns.isEmpty,
           incoming.count <= keyedRowLimit,
           let anchoredRow = uniqueRow(matching: firstVisibleKey, in: incoming) {
            return GridViewportPlacement(
                firstVisibleRow: anchoredRow,
                firstVisibleOffset: snapshot.firstVisibleOffset,
                selectedRows: [],
                revealsSelection: false
            )
        }

        let position = min(snapshot.firstVisiblePosition, incoming.rows.count - 1)
        return GridViewportPlacement(
            firstVisibleRow: incoming.rows[position].id,
            firstVisibleOffset: position == snapshot.firstVisiblePosition ? snapshot.firstVisibleOffset : 0,
            selectedRows: [],
            revealsSelection: false
        )
    }

    private static func uniqueRow(matching values: [String: String], in incoming: TableRows) -> RowID? {
        guard !values.isEmpty else { return nil }
        var columnValues: [(index: Int, value: String)] = []
        for (column, value) in values {
            guard let index = incoming.columns.firstIndex(of: column) else { return nil }
            columnValues.append((index, value))
        }

        var match: RowID?
        for row in incoming.rows where columnValues.allSatisfy({ row[$0.index].asText == $0.value }) {
            guard match == nil else { return nil }
            match = row.id
        }
        return match
    }
}
