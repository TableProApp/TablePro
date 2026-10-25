//
//  ResultComparisonGrid.swift
//  TablePro
//

import Combine
import SwiftUI
import TableProPluginKit

internal struct ResultComparisonGridLine: Equatable {
    internal let entry: ResultComparisonEntry
    internal let isLeft: Bool
}

@MainActor
internal final class ResultComparisonGridModel: ObservableObject {
    internal static let leadingColumnCount = 2

    internal struct LoadKey: Hashable {
        let comparisonId: UUID
        let filter: ResultComparisonFilter
    }

    internal let grid = HeldRowsGridAdapter(configuration: ResultComparisonGridModel.configuration)
    private(set) var lines: [ResultComparisonGridLine] = []
    private var loadedKey: LoadKey?

    internal var model: DataGridModel { grid.model }
    internal var tableRows: TableRows { grid.heldRows }

    private static var configuration: DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.showRowNumbers = false
        configuration.supportsValueFilter = false
        configuration.supportsColumnSort = false
        configuration.commands = [.freezeColumns]
        return configuration
    }

    @discardableResult
    internal func ensureLoaded(
        key: LoadKey,
        comparison: ResultComparison,
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing
    ) -> TableRows {
        guard loadedKey != key else { return tableRows }
        // A row is a line of this load, so a selection made against another load names nothing here.
        if loadedKey != nil {
            grid.model.clearSelection()
        }
        loadedKey = key
        lines = Self.lines(for: comparison.entries.filter { key.filter.matches($0.kind) })
        let rows = Self.tableRows(for: lines, left: left, right: right, pairing: pairing)
        var states: [RowID: RowVisualState] = [:]
        for (row, line) in zip(rows.rows, lines) {
            states[row.id] = Self.visualState(for: line)
        }
        grid.visualStates = states
        grid.setRows(rows)
        return tableRows
    }

    internal static func lines(for entries: [ResultComparisonEntry]) -> [ResultComparisonGridLine] {
        entries.flatMap { entry -> [ResultComparisonGridLine] in
            switch entry.kind {
            case .onlyLeft, .same:
                return [ResultComparisonGridLine(entry: entry, isLeft: true)]
            case .onlyRight:
                return [ResultComparisonGridLine(entry: entry, isLeft: false)]
            case .changed:
                return [
                    ResultComparisonGridLine(entry: entry, isLeft: true),
                    ResultComparisonGridLine(entry: entry, isLeft: false)
                ]
            }
        }
    }

    // The right result reads as the baseline: a row only on the left is marked new, one only on the right removed.
    internal static func visualState(for line: ResultComparisonGridLine) -> RowVisualState {
        let changed = Set(line.entry.changedPairs.map { $0 + leadingColumnCount })
        switch line.entry.kind {
        case .onlyLeft:
            return RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [], vocabulary: .resultComparison)
        case .onlyRight:
            return RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [], vocabulary: .resultComparison)
        case .changed where line.isLeft:
            return RowVisualState(
                isDeleted: false, isInserted: false, modifiedColumns: changed, vocabulary: .resultComparison
            )
        case .changed:
            return RowVisualState(
                isDeleted: false, isInserted: false, modifiedColumns: [], struckColumns: changed,
                vocabulary: .resultComparison
            )
        case .same:
            return RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [], vocabulary: .resultComparison)
        }
    }

    internal static func tableRows(
        for lines: [ResultComparisonGridLine],
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing
    ) -> TableRows {
        let rows = lines.enumerated().map { index, line in
            row(at: index, for: line, left: left, right: right, pairing: pairing)
        }
        return TableRows(
            rows: ContiguousArray(rows),
            columns: [String(localized: "Status"), String(localized: "Side")] + pairing.pairs.map(\.name),
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: leadingColumnCount)
                + pairing.pairs.map { displayType(for: $0, left: left, right: right) }
        )
    }

    internal static func statusTitle(for kind: ResultRowDifference) -> String {
        switch kind {
        case .onlyLeft: return String(localized: "Only Left")
        case .onlyRight: return String(localized: "Only Right")
        case .changed: return String(localized: "Changed")
        case .same: return String(localized: "Same")
        }
    }

    private static func row(
        at index: Int,
        for line: ResultComparisonGridLine,
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing
    ) -> Row {
        var values = ContiguousArray<PluginCellValue>()
        values.reserveCapacity(leadingColumnCount + pairing.pairs.count)
        values.append(.text(statusTitle(for: line.entry.kind)))
        values.append(.text(line.isLeft ? String(localized: "Left") : String(localized: "Right")))
        let source = line.isLeft
            ? line.entry.leftRow.map { left.rows[$0] }
            : line.entry.rightRow.map { right.rows[$0] }
        var absent: Set<Int> = []
        for (position, pair) in pairing.pairs.enumerated() {
            let column = line.isLeft ? pair.left : pair.right
            values.append(source?[column] ?? .null)
            if source?.isAbsent(column) == true { absent.insert(position + leadingColumnCount) }
        }
        return Row(id: .existing(index), values: values, absentColumns: absent)
    }

    private static func displayType(
        for pair: ResultColumnPairing.Pair,
        left: ResultComparisonSide,
        right: ResultComparisonSide
    ) -> ColumnType {
        CompareRowGridModel.displayType(source: left.columnType(at: pair.left), target: right.columnType(at: pair.right))
    }
}

internal struct ResultComparisonGrid: View {
    internal let comparison: ResultComparison
    internal let left: ResultComparisonSide
    internal let right: ResultComparisonSide
    internal let pairing: ResultColumnPairing
    internal let filter: ResultComparisonFilter

    @StateObject private var model = ResultComparisonGridModel()

    private var key: ResultComparisonGridModel.LoadKey {
        ResultComparisonGridModel.LoadKey(comparisonId: comparison.id, filter: filter)
    }

    // task(id:) runs with this body's values; onChange(of:) would run with the previous body's (measured).
    internal var body: some View {
        DataGridView(model: model.model)
            .task(id: key) { load() }
    }

    private func load() {
        model.ensureLoaded(key: key, comparison: comparison, left: left, right: right, pairing: pairing)
    }
}
