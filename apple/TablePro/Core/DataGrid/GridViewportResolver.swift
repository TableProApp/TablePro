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
    // Row ids are positional per page, so each row the selection names travels as its key.
    var selection: GridSelectionSnapshot = .empty
    var selectionKeys: [RowID: [String: String]] = [:]

    static let top = GridViewportSnapshot(firstVisiblePosition: 0, firstVisibleOffset: 0, firstVisibleKey: nil)

    var selectedKeys: [[String: String]] {
        selection.rowIDs.compactMap { selectionKeys[$0] }
    }

    // For a re-read that starts at the first row but keeps what is selected.
    var selectionOnly: GridViewportSnapshot {
        GridViewportSnapshot(
            firstVisiblePosition: 0,
            firstVisibleOffset: 0,
            firstVisibleKey: nil,
            selection: selection,
            selectionKeys: selectionKeys
        )
    }
}

internal struct GridViewportPlacement: Equatable {
    let firstVisibleRow: RowID?
    let firstVisibleOffset: CGFloat
    let selection: GridSelectionSnapshot
    let revealsSelection: Bool

    init(
        firstVisibleRow: RowID?,
        firstVisibleOffset: CGFloat,
        selection: GridSelectionSnapshot,
        revealsSelection: Bool
    ) {
        self.firstVisibleRow = firstVisibleRow
        self.firstVisibleOffset = firstVisibleOffset
        self.selection = selection
        self.revealsSelection = revealsSelection
    }

    init(firstVisibleRow: RowID?, firstVisibleOffset: CGFloat, selectedRows: [RowID], revealsSelection: Bool) {
        self.init(
            firstVisibleRow: firstVisibleRow,
            firstVisibleOffset: firstVisibleOffset,
            selection: selectedRows.isEmpty
                ? .empty
                : GridSelectionSnapshot(rowIDs: selectedRows, rectangles: [], activeCell: nil, anchor: nil),
            revealsSelection: revealsSelection
        )
    }

    var selectedRows: [RowID] { selection.rowIDs }

    static let firstRow = GridViewportPlacement(
        firstVisibleRow: nil,
        firstVisibleOffset: 0,
        selection: .empty,
        revealsSelection: false
    )
}

extension GridViewportPlacement {
    func selecting(_ selection: GridSelectionSnapshot) -> GridViewportPlacement {
        guard selection != .empty else { return self }
        return GridViewportPlacement(
            firstVisibleRow: firstVisibleRow,
            firstVisibleOffset: firstVisibleOffset,
            selection: selection,
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
        selection: GridSelectionSnapshot = .empty,
        keyColumns: [String],
        isCellModified: (RowID, Int) -> Bool = { _, _ in false }
    ) -> GridViewportSnapshot {
        let isKeyed = !keyColumns.isEmpty && tableRows.count <= keyedRowLimit
        let order = DataGridRowOrder(filteredIDs: displayIDs, revision: 0)
        func key(of row: Row?) -> [String: String]? {
            row.flatMap { savedKey(of: $0, in: tableRows, keyColumns: keyColumns, isCellModified: isCellModified) }
        }
        var selectionKeys: [RowID: [String: String]] = [:]
        if isKeyed {
            for rowID in selection.namedRowIDs {
                selectionKeys[rowID] = key(of: tableRows.row(withID: rowID))
            }
        }
        return GridViewportSnapshot(
            firstVisiblePosition: max(0, firstVisibleDisplayRow),
            firstVisibleOffset: max(0, firstVisibleOffset),
            firstVisibleKey: isKeyed ? key(of: order.row(at: firstVisibleDisplayRow, in: tableRows)) : nil,
            selection: isKeyed ? selection : .empty,
            selectionKeys: selectionKeys
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
                .selecting(remappedSelection(snapshot, in: incoming, keyColumns: keyColumns))
        case .keepPlace:
            return keptPlace(from: snapshot, in: incoming, displayIDs: displayIDs, keyColumns: keyColumns)
                .selecting(remappedSelection(snapshot, in: incoming, keyColumns: keyColumns))
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

        // The snapshot counted display positions, which a value filter makes differ from storage.
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

    // One pass, so a large selection does not rescan per row; a repeated key matches nothing, as in uniqueRow(matching:in:).
    private static func remappedSelection(
        _ snapshot: GridViewportSnapshot,
        in incoming: TableRows,
        keyColumns: [String]
    ) -> GridSelectionSnapshot {
        guard !snapshot.selectionKeys.isEmpty, !keyColumns.isEmpty, incoming.count <= keyedRowLimit else { return .empty }
        let indices = keyColumns.compactMap { incoming.columns.firstIndex(of: $0) }
        guard indices.count == keyColumns.count else { return .empty }

        var rowByKey: [[String]: RowID] = [:]
        var repeated = Set<[String]>()
        for row in incoming.rows where !row.id.isInserted {
            let values = indices.compactMap { row[$0].asText }
            guard values.count == indices.count else { continue }
            if rowByKey.updateValue(row.id, forKey: values) != nil {
                repeated.insert(values)
            }
        }
        var incomingRows: [RowID: RowID] = [:]
        for (outgoing, key) in snapshot.selectionKeys {
            let values = keyColumns.compactMap { key[$0] }
            guard values.count == keyColumns.count, !repeated.contains(values), let row = rowByKey[values] else { continue }
            incomingRows[outgoing] = row
        }
        return snapshot.selection.mappingRows { incomingRows[$0] }
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
