//
//  CompareRowGrid.swift
//  TablePro
//
//  One table's row differences as rows: every column, the source line over the
//  target line for a changed row, and the differing cells marked.
//
//  The data grid draws it, read-only, so a table of any width costs what the
//  grid costs rather than a view per cell. Its marks are the grid's own: a row
//  only in the source is underlined as an inserted row is, a row only in the
//  target is struck through, and a changed value is underlined on the source
//  line and struck through on the target line. Each carries a tint as a second
//  cue and reads to VoiceOver in comparison words, not in editing ones.
//

import SwiftUI
import TableProPluginKit

internal struct CompareRowGridLine {
    internal let entry: RowDiffEntry
    internal let side: ComparisonSide
    internal let opensEntry: Bool
}

@MainActor
internal final class CompareRowGridModel: DataGridViewDelegate {
    internal static let includeColumn = 0
    internal static let leadingColumnCount = 3

    internal struct LoadKey: Hashable {
        let planId: String
        let answer: String?
        let columns: [String]
        let filter: RowDiffFilter
        let entryCount: Int
    }

    private(set) var lines: [CompareRowGridLine] = []
    private(set) var tableRows = TableRows()
    private var states: [RowVisualState] = []
    private var loadedKey: LoadKey?
    private var planId = ""
    private weak var session: CompareSyncSession?

    /// A grid row is a display position, which stops matching the line order as soon as a column's
    /// value filter narrows the grid, so every row the grid names is resolved back through it.
    private weak var coordinator: TableViewCoordinator?

    internal func ensureLoaded(
        key: LoadKey,
        plan: DataComparePlan,
        entries: [RowDiffEntry],
        session: CompareSyncSession
    ) -> TableRows {
        self.session = session
        guard loadedKey != key else { return tableRows }
        loadedKey = key
        planId = plan.id
        lines = entries.flatMap(Self.lines(for:))
        let columns = plan.columnNames
        states = lines.map { Self.visualState(for: $0, columns: columns) }
        tableRows = TableRows(
            rows: ContiguousArray(lines.enumerated().map { index, line in
                Row(id: .existing(index), values: Self.values(for: line, columns: columns))
            }),
            columns: [
                String(localized: "Include"),
                String(localized: "Change"),
                String(localized: "Side")
            ] + columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: Self.leadingColumnCount)
                + plan.columns.map { Self.displayType(for: $0) }
        )
        return tableRows
    }

    private static func displayType(for column: CompareColumn) -> ColumnType {
        displayType(source: column.sourceColumnType, target: column.targetColumnType)
    }

    // Both lines format through one type, so a DATE beside a TIMESTAMP falls back to text rather than hide the time.
    internal static func displayType(source: ColumnType?, target: ColumnType?) -> ColumnType {
        guard let source else { return target ?? .text(rawType: nil) }
        guard let target else { return source }
        return source.displayShape == target.displayShape ? source : .text(rawType: nil)
    }

    internal static func lines(for entry: RowDiffEntry) -> [CompareRowGridLine] {
        switch entry.kind {
        case .insert, .identical:
            return [CompareRowGridLine(entry: entry, side: .source, opensEntry: true)]
        case .delete:
            return [CompareRowGridLine(entry: entry, side: .target, opensEntry: true)]
        case .update, .conflict:
            return [
                CompareRowGridLine(entry: entry, side: .source, opensEntry: true),
                CompareRowGridLine(entry: entry, side: .target, opensEntry: false)
            ]
        }
    }

    internal static func visualState(for line: CompareRowGridLine, columns: [String]) -> RowVisualState {
        let changed = Set(line.entry.cellDifferences.compactMap { difference in
            columns
                .firstIndex { $0.caseInsensitiveCompare(difference.column) == .orderedSame }
                .map { $0 + leadingColumnCount }
        })
        switch line.entry.kind {
        case .insert:
            return RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [], vocabulary: .comparison)
        case .delete:
            return RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [], vocabulary: .comparison)
        case .update, .conflict:
            guard line.side == .source else {
                return RowVisualState(
                    isDeleted: false, isInserted: false, modifiedColumns: [],
                    struckColumns: changed, vocabulary: .comparison
                )
            }
            return RowVisualState(
                isDeleted: false, isInserted: false, modifiedColumns: changed, vocabulary: .comparison
            )
        case .identical:
            return RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [], vocabulary: .comparison)
        }
    }

    private static func values(for line: CompareRowGridLine, columns: [String]) -> ContiguousArray<PluginCellValue> {
        let row = line.side == .source ? line.entry.sourceRow : line.entry.targetRow
        var values = ContiguousArray<PluginCellValue>()
        values.reserveCapacity(leadingColumnCount + columns.count)
        values.append(.null)
        values.append(.text(CompareStatusStyle.title(for: line.entry.kind)))
        values.append(.text(line.side == .source ? String(localized: "Source") : String(localized: "Target")))
        for column in columns {
            values.append(row?.value(for: column) ?? .null)
        }
        return values
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

    internal func dataGridCheckboxState(row: Int, column: Int) -> Bool? {
        guard column == Self.includeColumn, let index = lineIndex(forDisplayRow: row) else { return nil }
        let line = lines[index]
        guard line.opensEntry, line.entry.kind.isDifference,
              let session, let plan = session.dataPlans.first(where: { $0.id == planId }) else { return nil }
        return session.isRowIncluded(line.entry, in: plan)
    }

    // The delegate's default copies nothing, which left Copy and Select All then Copy silent on this grid.
    internal func dataGridCopyRows(_ indices: Set<Int>) {
        coordinator?.copyRowsAsTSV(at: indices, includeHeaders: false)
    }

    internal func dataGridSetCheckbox(_ isOn: Bool, rows: IndexSet, column: Int) {
        guard column == Self.includeColumn, let session else { return }
        let entries = rows.compactMap { row -> RowDiffEntry? in
            guard let index = lineIndex(forDisplayRow: row), lines[index].opensEntry else { return nil }
            return lines[index].entry
        }
        session.setRowsIncluded(isOn, entries: entries, planId: planId)
    }
}

internal struct CompareRowGrid: View {
    @ObservedObject internal var session: CompareSyncSession
    internal let plan: DataComparePlan
    internal let filter: RowDiffFilter
    internal let entries: [RowDiffEntry]

    @State private var model = CompareRowGridModel()
    @State private var changeManager = AnyChangeManager(DataChangeManager())
    @State private var selectedRows: Set<Int> = []
    @State private var columnLayout = ColumnLayoutState()

    internal var body: some View {
        let key = CompareRowGridModel.LoadKey(
            planId: plan.id,
            answer: plan.summary?.answerIdentity,
            columns: plan.columnNames,
            filter: filter,
            entryCount: entries.count
        )
        let model = model
        let plan = plan
        let entries = entries
        let session = session
        return DataGridView(
            tableRowsProvider: { model.ensureLoaded(key: key, plan: plan, entries: entries, session: session) },
            changeManager: changeManager,
            isEditable: false,
            configuration: DataGridConfiguration(
                databaseType: session.source?.databaseType,
                showRowNumbers: false,
                checkboxColumns: [CompareRowGridModel.includeColumn],
                supportsColumnCommands: false,
                supportsValueFilter: false,
                supportsColumnSort: false
            ),
            delegate: model,
            selectedRowIndices: $selectedRows,
            sortState: .constant(SortState()),
            columnLayout: $columnLayout,
            /// The exclusions ride along, so including or excluding every listed row from the menu
            /// repaints the checkboxes rather than leaving them until the next click or scroll.
            contentRevision: key.hashValue ^ plan.excludedRowKeys.hashValue
        )
        .onChange(of: key) { _ in
            selectedRows = []
        }
    }
}

private extension ColumnType {
    enum DisplayShape {
        case text, integer, decimal, date, timestamp, datetime, boolean, blob, json, enumType, set, spatial, vector, array
    }

    var displayShape: DisplayShape {
        switch self {
        case .text: return .text
        case .integer: return .integer
        case .decimal: return .decimal
        case .date: return .date
        case .timestamp: return .timestamp
        case .datetime: return .datetime
        case .boolean: return .boolean
        case .blob: return .blob
        case .json: return .json
        case .enumType: return .enumType
        case .set: return .set
        case .spatial: return .spatial
        case .vector: return .vector
        case .array: return .array
        }
    }
}
