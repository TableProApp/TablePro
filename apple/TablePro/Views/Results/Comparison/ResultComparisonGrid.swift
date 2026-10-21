//
//  ResultComparisonGrid.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct ResultComparisonGridLine: Equatable {
    internal let entry: ResultComparisonEntry
    internal let isLeft: Bool
}

@MainActor
internal final class ResultComparisonGridModel: DataGridViewDelegate {
    internal static let leadingColumnCount = 2

    internal struct LoadKey: Hashable {
        let comparisonId: UUID
        let filter: ResultComparisonFilter
    }

    private(set) var lines: [ResultComparisonGridLine] = []
    private(set) var tableRows = TableRows()
    private var states: [RowVisualState] = []
    private var loadedKey: LoadKey?

    // A grid row is a display position; the grid's own value filter can reorder it.
    private weak var coordinator: TableViewCoordinator?

    internal func ensureLoaded(
        key: LoadKey,
        comparison: ResultComparison,
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing
    ) -> TableRows {
        guard loadedKey != key else { return tableRows }
        loadedKey = key
        lines = Self.lines(for: comparison.entries.filter { key.filter.matches($0.kind) })
        states = lines.map(Self.visualState(for:))
        tableRows = Self.tableRows(for: lines, left: left, right: right, pairing: pairing)
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

    private func lineIndex(forDisplayRow row: Int) -> Int? {
        let index = coordinator?.tableRowsIndex(forDisplayRow: row) ?? row
        return lines.indices.contains(index) ? index : nil
    }

    // MARK: - DataGridViewDelegate

    internal func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        coordinator = tableViewCoordinator
    }

    internal func dataGridVisualState(forRow row: Int) -> RowVisualState? {
        guard let index = lineIndex(forDisplayRow: row), states.indices.contains(index) else { return nil }
        return states[index]
    }

    internal func dataGridCopyRows(_ indices: Set<Int>) {
        coordinator?.copyRowsAsTSV(at: indices, includeHeaders: false)
    }
}

internal struct ResultComparisonGrid: View {
    internal let comparison: ResultComparison
    internal let left: ResultComparisonSide
    internal let right: ResultComparisonSide
    internal let pairing: ResultColumnPairing
    internal let filter: ResultComparisonFilter

    @State private var model = ResultComparisonGridModel()
    @State private var changeManager = AnyChangeManager(DataChangeManager())
    @State private var selectedRows: Set<Int> = []
    @State private var columnLayout = ColumnLayoutState()

    internal var body: some View {
        let key = ResultComparisonGridModel.LoadKey(comparisonId: comparison.id, filter: filter)
        let model = model
        let comparison = comparison
        let left = left
        let right = right
        let pairing = pairing
        var configuration = DataGridConfiguration()
        configuration.showRowNumbers = false
        configuration.supportsColumnCommands = false
        configuration.supportsValueFilter = false
        configuration.supportsColumnSort = false
        return DataGridView(
            tableRowsProvider: {
                model.ensureLoaded(key: key, comparison: comparison, left: left, right: right, pairing: pairing)
            },
            changeManager: changeManager,
            isEditable: false,
            configuration: configuration,
            delegate: model,
            selectedRowIndices: $selectedRows,
            sortState: .constant(SortState()),
            columnLayout: $columnLayout,
            contentRevision: key.hashValue
        )
        .onChange(of: key) { _ in
            selectedRows = []
        }
    }
}
