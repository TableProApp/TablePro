//
//  CompareRowGrid.swift
//  TablePro
//

import Combine
import SwiftUI
import TableProPluginKit

internal struct CompareRowGridLine {
    internal let entry: RowDiffEntry
    internal let side: ComparisonSide
    internal let opensEntry: Bool
}

@MainActor
internal final class CompareRowGridModel: ObservableObject {
    internal static let includeColumn = 0
    internal static let leadingColumnCount = 3

    internal struct LoadKey: Hashable {
        let planId: String
        let answer: String?
        let columns: [String]
        let filter: RowDiffFilter
        let entryCount: Int
    }

    internal let grid = HeldRowsGridAdapter(configuration: CompareRowGridModel.configuration(databaseType: nil))
    private(set) var lines: [CompareRowGridLine] = []
    private var loadedKey: LoadKey?
    private var planId = ""
    private weak var session: CompareSyncSession?

    internal init() {
        grid.checkboxState = { [weak self] rowID, column in
            self?.checkboxState(rowID: rowID, column: column)
        }
        grid.checkboxChange = { [weak self] isOn, rowIDs, column in
            self?.setIncluded(isOn, rowIDs: rowIDs, column: column)
        }
    }

    internal var model: DataGridModel { grid.model }
    internal var tableRows: TableRows { grid.heldRows }

    private static func configuration(databaseType: DatabaseType?) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.traits = DataGridEngineTraits(databaseType: databaseType)
        configuration.showRowNumbers = false
        configuration.checkboxColumns = [includeColumn]
        configuration.supportsValueFilter = false
        configuration.supportsColumnSort = false
        configuration.commands = [.freezeColumns]
        return configuration
    }

    @discardableResult
    internal func ensureLoaded(
        key: LoadKey,
        plan: DataComparePlan,
        entries: [RowDiffEntry],
        session: CompareSyncSession
    ) -> TableRows {
        self.session = session
        grid.model.configuration = Self.configuration(databaseType: session.source?.databaseType)
        guard loadedKey != key else { return tableRows }
        // A row is a line of this load, so a selection made against another load names nothing here.
        if loadedKey != nil {
            grid.model.clearSelection()
        }
        loadedKey = key
        planId = plan.id
        lines = entries.flatMap(Self.lines(for:))
        let columns = plan.columnNames
        var states: [RowID: RowVisualState] = [:]
        let rows = ContiguousArray(lines.enumerated().map { index, line -> Row in
            let rowID = RowID.existing(index)
            states[rowID] = Self.visualState(for: line, columns: columns)
            return Row(id: rowID, values: Self.values(for: line, columns: columns))
        })
        grid.visualStates = states
        grid.setRows(TableRows(
            rows: rows,
            columns: [
                String(localized: "Include"),
                String(localized: "Change"),
                String(localized: "Side")
            ] + columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: Self.leadingColumnCount)
                + plan.columns.map { Self.displayType(for: $0) }
        ))
        return tableRows
    }

    // An exclusion changed from the menu or from Space: the checkboxes repaint, the rows and selection stay.
    internal func redrawCheckboxes(forLines lineIndexes: [Int]? = nil) {
        let indexes = lineIndexes ?? Array(lines.indices)
        grid.redrawCells(Set(indexes.compactMap { line -> CellPosition? in
            grid.storageIndex(of: .existing(line)).map { CellPosition(row: $0, column: Self.includeColumn) }
        }))
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

    private func lineIndex(of rowID: RowID) -> Int? {
        guard case .existing(let index) = rowID, lines.indices.contains(index) else { return nil }
        return index
    }

    private func checkboxState(rowID: RowID, column: DataGridColumn) -> Bool? {
        guard column.dataIndex == Self.includeColumn, let index = lineIndex(of: rowID) else { return nil }
        let line = lines[index]
        guard line.opensEntry, line.entry.kind.isDifference,
              let session, let plan = session.dataPlans.first(where: { $0.id == planId }) else { return nil }
        return session.isRowIncluded(line.entry, in: plan)
    }

    private func setIncluded(_ isOn: Bool, rowIDs: [RowID], column: DataGridColumn) {
        guard column.dataIndex == Self.includeColumn, let session else { return }
        let indexes = rowIDs.compactMap(lineIndex(of:)).filter { lines[$0].opensEntry }
        session.setRowsIncluded(isOn, entries: indexes.map { lines[$0].entry }, planId: planId)
        redrawCheckboxes(forLines: indexes)
    }
}

internal struct CompareRowGrid: View {
    @ObservedObject internal var session: CompareSyncSession
    internal let plan: DataComparePlan
    internal let filter: RowDiffFilter
    internal let entries: [RowDiffEntry]

    @StateObject private var model = CompareRowGridModel()

    private var key: CompareRowGridModel.LoadKey {
        CompareRowGridModel.LoadKey(
            planId: plan.id,
            answer: plan.summary?.answerIdentity,
            columns: plan.columnNames,
            filter: filter,
            entryCount: entries.count
        )
    }

    // task(id:) runs with this body's values; onChange(of:) would run with the previous body's (measured).
    internal var body: some View {
        DataGridView(model: model.model)
            .task(id: key) { load() }
            .onChange(of: plan.excludedRowKeys) { _ in model.redrawCheckboxes() }
    }

    private func load() {
        model.ensureLoaded(key: key, plan: plan, entries: entries, session: session)
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
