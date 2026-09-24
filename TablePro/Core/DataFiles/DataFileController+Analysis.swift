//
//  DataFileController+Analysis.swift
//  TablePro
//

import Foundation
import TableProTabular

extension DataFileController {
    func statisticsRequest(for id: TabularColumnID) -> DataFileStatisticsRequest? {
        guard let table, let name = columnNames.name(for: id) else { return nil }
        return DataFileStatisticsRequest(
            table: table,
            column: id,
            columnName: name,
            kind: kind(of: id),
            keys: visibleKeys(),
            isFiltered: displayKeys != nil
        )
    }

    func addEqualsFilter(column id: TabularColumnID, value: TabularValueCount) {
        guard let name = columnNames.name(for: id) else { return }
        let filter = value.isEmpty
            ? TableFilter(columnName: name, filterOperator: .isEmpty)
            : TableFilter(columnName: name, filterOperator: .equal, value: value.value)
        addFilter(filter)
    }

    func addFilter(_ filter: TableFilter) {
        filterState = TabFilterState.cellFilterState(filterState, adding: filter)
        runQuery()
    }

    func removeDuplicateRows(comparing columns: [TabularColumnID], options: TabularDuplicateOptions) {
        guard !columns.isEmpty else { return }
        let keys = visibleKeys()
        runMutation(
            title: String(localized: "Finding Duplicates…"),
            actionName: String(localized: "Remove Duplicates")
        ) { table, progress in
            let duplicates = try await TabularDuplicates.duplicateKeys(
                comparing: columns,
                keys: keys,
                in: table,
                options: options,
                progress: progress
            )
            guard !duplicates.isEmpty else {
                return DataFileMutationOutcome(table: nil, message: String(localized: "No duplicate rows found."))
            }
            let removed = Set(duplicates)
            var updated = table
            updated.deleteRows(keys: removed)
            return DataFileMutationOutcome(
                table: updated,
                message: Self.duplicatesMessage(removed: removed.count, remaining: updated.rowCount),
                removedKeys: removed
            )
        }
    }

    nonisolated static func duplicatesMessage(removed: Int, remaining: Int) -> String {
        String(
            format: String(localized: "Removed %@ duplicate rows. %@ rows remain."),
            removed.formatted(),
            remaining.formatted()
        )
    }
}

struct DataFileStatisticsRequest: Sendable {
    let table: TabularTable
    let column: TabularColumnID
    let columnName: String
    let kind: TabularInferredKind
    let keys: [Int]
    let isFiltered: Bool

    @concurrent
    func summarize(progress: @escaping @Sendable (Double) -> Void) async throws -> TabularColumnSummary {
        try await TabularColumnStatistics.summarize(
            column: column,
            kind: kind,
            keys: keys,
            in: table,
            progress: progress
        )
    }
}
