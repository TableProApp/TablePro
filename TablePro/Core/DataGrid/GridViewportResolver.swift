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
    var selectedKeys: [[String: String]] = []

    static let top = GridViewportSnapshot(firstVisiblePosition: 0, firstVisibleOffset: 0, firstVisibleKey: nil)

    /// The selection alone, for a re-read that starts at the first row but keeps what is selected.
    var selectionOnly: GridViewportSnapshot {
        GridViewportSnapshot(firstVisiblePosition: 0, firstVisibleOffset: 0, firstVisibleKey: nil, selectedKeys: selectedKeys)
    }
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

extension GridViewportPlacement {
    func selecting(_ rows: [RowID]) -> GridViewportPlacement {
        guard !rows.isEmpty else { return self }
        return GridViewportPlacement(
            firstVisibleRow: firstVisibleRow,
            firstVisibleOffset: firstVisibleOffset,
            selectedRows: rows,
            revealsSelection: revealsSelection
        )
    }
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
        selectedDisplayRows: [Int] = [],
        keyColumns: [String],
        isCellModified: (RowID, Int) -> Bool = { _, _ in false }
    ) -> GridViewportSnapshot {
        let isKeyed = !keyColumns.isEmpty && tableRows.count <= keyedRowLimit
        func key(_ displayRow: Int) -> [String: String]? {
            DisplayRowMapping.row(forDisplay: displayRow, displayIDs: displayIDs, in: tableRows)
                .flatMap { savedKey(of: $0, in: tableRows, keyColumns: keyColumns, isCellModified: isCellModified) }
        }
        return GridViewportSnapshot(
            firstVisiblePosition: max(0, firstVisibleDisplayRow),
            firstVisibleOffset: max(0, firstVisibleOffset),
            firstVisibleKey: isKeyed ? key(firstVisibleDisplayRow) : nil,
            selectedKeys: isKeyed ? selectedDisplayRows.sorted().compactMap { key($0) } : []
        )
    }

    static func placement(
        for intent: GridReloadIntent,
        from snapshot: GridViewportSnapshot,
        in incoming: TableRows,
        displayIDs: [RowID]? = nil,
        keyColumns: [String]
    ) -> GridViewportPlacement {
        guard !incoming.rows.isEmpty else { return .firstRow }
        switch intent {
        case .firstRow:
            return GridViewportPlacement.firstRow
                .selecting(rows(matching: snapshot.selectedKeys, in: incoming, keyColumns: keyColumns))
        case .keepPlace:
            return keptPlace(from: snapshot, in: incoming, displayIDs: displayIDs, keyColumns: keyColumns)
                .selecting(rows(matching: snapshot.selectedKeys, in: incoming, keyColumns: keyColumns))
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
        displayIDs: [RowID]?,
        keyColumns: [String]
    ) -> GridViewportPlacement {
        guard snapshot.firstVisiblePosition > 0 || snapshot.firstVisibleOffset > 0 else { return .firstRow }

        if let firstVisibleKey = snapshot.firstVisibleKey,
           !keyColumns.isEmpty,
           incoming.count <= keyedRowLimit,
           let anchoredRow = uniqueRow(matching: firstVisibleKey, in: incoming),
           displayIDs?.contains(anchoredRow) ?? true {
            return GridViewportPlacement(
                firstVisibleRow: anchoredRow,
                firstVisibleOffset: snapshot.firstVisibleOffset,
                selectedRows: [],
                revealsSelection: false
            )
        }

        /// The snapshot counted display positions, which a value filter makes differ from storage.
        let shown = displayIDs ?? incoming.rows.map(\.id)
        guard !shown.isEmpty else { return .firstRow }
        let position = min(snapshot.firstVisiblePosition, shown.count - 1)
        return GridViewportPlacement(
            firstVisibleRow: shown[position],
            firstVisibleOffset: position == snapshot.firstVisiblePosition ? snapshot.firstVisibleOffset : 0,
            selectedRows: [],
            revealsSelection: false
        )
    }

    /// One pass over the incoming rows, so restoring a large selection does not rescan them per row.
    /// A key that repeats matches nothing, as in `uniqueRow(matching:in:)`.
    private static func rows(
        matching keys: [[String: String]],
        in incoming: TableRows,
        keyColumns: [String]
    ) -> [RowID] {
        guard !keys.isEmpty, !keyColumns.isEmpty, incoming.count <= keyedRowLimit else { return [] }
        let indices = keyColumns.compactMap { incoming.columns.firstIndex(of: $0) }
        guard indices.count == keyColumns.count else { return [] }

        var rowByKey: [[String]: RowID] = [:]
        var repeated = Set<[String]>()
        for row in incoming.rows where !row.id.isInserted {
            let values = indices.compactMap { row[$0].asText }
            guard values.count == indices.count else { continue }
            if rowByKey.updateValue(row.id, forKey: values) != nil {
                repeated.insert(values)
            }
        }
        return keys.compactMap { key in
            let values = keyColumns.compactMap { key[$0] }
            guard values.count == keyColumns.count, !repeated.contains(values) else { return nil }
            return rowByKey[values]
        }
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
