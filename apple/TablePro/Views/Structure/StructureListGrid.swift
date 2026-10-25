//
//  StructureListGrid.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProPluginKit

internal struct StructureListRow<ID: Hashable>: Hashable {
    internal let id: ID
    internal let values: [String]
    // Keyed by column, for a cell whose drawn text reads wrong aloud, such as YES for Enabled.
    internal var spokenValues: [Int: String] = [:]
    internal var tones: [Int: StructureListTone] = [:]
}

// Status hues stay system under every theme, and the text still turns to the selection text on an
// emphasized selection, like the rest of the row.
internal enum StructureListTone: Hashable {
    case positive
    case caution
    case critical
    case secondary

    internal var color: NSColor {
        switch self {
        case .positive: return .systemGreen
        case .caution: return .systemOrange
        case .critical: return .systemRed
        case .secondary: return .secondaryLabelColor
        }
    }
}

@MainActor
internal final class StructureListSelection<ID: Hashable>: ObservableObject {
    @Published internal var ids: Set<ID> = []
}

// The grid behind a read-only Structure or dashboard list. Each list row keeps one RowID for as long as
// its id is listed, so a refresh or a sort keeps the selection on the same record.
@MainActor
internal final class StructureListGridModel<ID: Hashable>: ObservableObject {
    internal let grid = HeldRowsGridAdapter(configuration: DataGridConfiguration())
    internal var onSelect: ((Set<ID>) -> Void)?

    internal private(set) var rowIDs: [ID] = []
    private var rowIDByID: [ID: RowID] = [:]
    private var idByRowID: [RowID: ID] = [:]
    private var nextRowNumber = 0
    private var loadedColumns: [String]?
    private var loadedRows: [StructureListRow<ID>]?
    private var syncedIDs: Set<ID> = []
    private let accessibilityLabel: String?

    internal init(accessibilityLabel: String? = nil) {
        self.accessibilityLabel = accessibilityLabel
        grid.onSelectionChange = { [weak self] rowIDs in
            self?.gridSelectionDidChange(rowIDs)
        }
    }

    internal var model: DataGridModel { grid.model }
    internal var tableRows: TableRows { grid.heldRows }

    internal func load(
        columns: [String],
        rows: [StructureListRow<ID>],
        defaultWidths: [CGFloat],
        minimumWidths: [CGFloat],
        databaseType: DatabaseType,
        sortState: SortState?
    ) {
        var configuration = Self.configuration(
            columns: columns,
            minimumWidths: minimumWidths,
            databaseType: databaseType,
            sorts: sortState != nil
        )
        configuration.accessibilityLabel = accessibilityLabel
        grid.model.configuration = configuration
        if let sortState {
            grid.model.store.sortState = sortState
        }
        guard loadedColumns != columns || loadedRows != rows else { return }
        if loadedColumns != columns {
            grid.model.store.columnLayout = StructureListGrid<ID>.layout(
                grid.model.store.columnLayout, columns: columns, defaultWidths: defaultWidths
            )
        }
        loadedColumns = columns
        loadedRows = rows
        grid.setRows(makeTableRows(for: rows, columns: columns))
    }

    private static func configuration(
        columns: [String],
        minimumWidths: [CGFloat],
        databaseType: DatabaseType,
        sorts: Bool
    ) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.traits = DataGridEngineTraits(databaseType: databaseType)
        configuration.supportsValueFilter = false
        configuration.appliesRowCopyFormat = true
        configuration.supportsColumnSort = sorts
        configuration.columnMinimumWidths = StructureListGrid<ID>.minimumWidths(minimumWidths, columns: columns)
        configuration.commands = [.freezeColumns]
        return configuration
    }

    private func makeTableRows(for listed: [StructureListRow<ID>], columns: [String]) -> TableRows {
        var keptRowIDs: [ID: RowID] = [:]
        var rows = ContiguousArray<Row>()
        rows.reserveCapacity(listed.count)
        var tones: [RowID: [Int: NSColor]] = [:]
        var spoken: [RowID: [Int: String]] = [:]
        for row in listed {
            let rowID: RowID
            if keptRowIDs[row.id] == nil {
                rowID = rowIDByID[row.id] ?? mintRowID()
                keptRowIDs[row.id] = rowID
            } else {
                rowID = mintRowID()
            }
            var values = ContiguousArray(row.values.prefix(columns.count).map(PluginCellValue.text))
            while values.count < columns.count {
                values.append(.text(""))
            }
            rows.append(Row(id: rowID, values: values))
            if !row.tones.isEmpty {
                tones[rowID] = row.tones.mapValues(\.color)
            }
            if !row.spokenValues.isEmpty {
                spoken[rowID] = row.spokenValues
            }
        }
        rowIDByID = keptRowIDs
        idByRowID = Dictionary(keptRowIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        rowIDs = listed.map(\.id)
        grid.textTones = tones
        grid.spokenTexts = spoken
        return TableRows(
            rows: rows,
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: columns.count),
            columnNullable: Dictionary(columns.map { ($0, false) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private func mintRowID() -> RowID {
        defer { nextRowNumber += 1 }
        return .existing(nextRowNumber)
    }

    internal func id(for rowID: RowID) -> ID? {
        idByRowID[rowID]
    }

    internal func rowID(for id: ID) -> RowID? {
        rowIDByID[id]
    }

    internal var selectedIDs: Set<ID> {
        Set(grid.model.selectedRowIDs.compactMap { idByRowID[$0] })
    }

    // The owner moved the selection itself.
    internal func syncSelection(_ ids: Set<ID>) {
        syncedIDs = ids
        guard selectedIDs != ids else { return }
        let rowIDs = ids.compactMap { rowIDByID[$0] }
        if rowIDs.isEmpty {
            grid.model.clearSelection()
        } else {
            grid.model.selectRows(rowIDs)
        }
    }

    // A filter or a reload that hides selected records shrinks the grid's selection; that is not the user's pick.
    private func gridSelectionDidChange(_ rowIDs: [RowID]) {
        let ids = Set(rowIDs.compactMap { idByRowID[$0] })
        guard ids != syncedIDs.filter({ rowIDByID[$0] != nil }) else { return }
        syncedIDs = ids
        onSelect?(ids)
    }
}

// A nil `sortState` turns header sorting off. `defaultWidths` and `minimumWidths` follow `columns` by index.
internal struct StructureListGrid<ID: Hashable>: View {
    @ObservedObject internal var model: StructureListGridModel<ID>
    internal let columns: [String]
    internal var defaultWidths: [CGFloat] = []
    internal var minimumWidths: [CGFloat] = []
    internal let rows: [StructureListRow<ID>]
    internal let databaseType: DatabaseType
    internal let selectedIDs: Set<ID>
    internal let select: (Set<ID>) -> Void
    internal var sortState: Binding<SortState>?

    internal static func layout(
        _ layout: ColumnLayoutState,
        columns: [String],
        defaultWidths: [CGFloat]
    ) -> ColumnLayoutState {
        var filled = layout
        for (column, width) in zip(columns, defaultWidths) where filled.columnWidths[column] == nil {
            filled.columnWidths[column] = width
        }
        return filled
    }

    internal static func minimumWidths(_ widths: [CGFloat], columns: [String]) -> [String: CGFloat] {
        Dictionary(zip(columns, widths), uniquingKeysWith: { first, _ in first })
    }

    private struct LoadKey: Equatable {
        let columns: [String]
        let rows: [StructureListRow<ID>]
        let sortState: SortState?
    }

    // task(id:) runs with this body's values; onChange(of:) would run with the previous body's (measured).
    internal var body: some View {
        DataGridView(model: model.model)
            .task(id: LoadKey(columns: columns, rows: rows, sortState: sortState?.wrappedValue)) { load() }
            .onChange(of: selectedIDs) { model.syncSelection($0) }
    }

    private func load() {
        let sortState = sortState
        model.onSelect = select
        model.grid.onSortChange = sortState.map { binding in { binding.wrappedValue = $0 } }
        model.load(
            columns: columns,
            rows: rows,
            defaultWidths: defaultWidths,
            minimumWidths: minimumWidths,
            databaseType: databaseType,
            sortState: sortState?.wrappedValue
        )
        model.syncSelection(selectedIDs)
    }
}
