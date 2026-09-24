//
//  DataFileController+Query.swift
//  TablePro
//

import Foundation
import TableProTabular
import TableProTabularIO

extension DataFileController {
    static let queryDebounce: Duration = .milliseconds(250)

    var allowsNullLiterals: Bool {
        guard let format = kind?.format else { return false }
        switch format {
        case .json, .jsonLines:
            return true
        case .delimited, .workbook:
            return false
        }
    }

    var hasActiveQuery: Bool {
        !filterState.appliedFilters.isEmpty || !trimmedSearchText.isEmpty || sortState.isSorting
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scheduleQuery() {
        setDebounceTask(Task { [weak self] in
            try? await Task.sleep(for: Self.queryDebounce)
            guard !Task.isCancelled else { return }
            self?.runQuery()
        })
    }

    func applyAllFilters() {
        filterState.commit = .all
        runQuery()
    }

    func applySoloFilter(_ filter: TableFilter) {
        filterState.commit = .solo(filter.id)
        runQuery()
    }

    func updateSort(_ state: SortState) {
        sortState = state
        runQuery()
    }

    func runQuery() {
        setDebounceTask(nil)
        guard let table else { return }
        let revision = nextQueryRevision()
        filterState.executedFilters = filterState.appliedFilters
        let predicate = currentPredicate()
        let sortKeys = currentSortKeys()
        selectedRowIndices = []
        pageOffset = 0
        guard !predicate.isTrivial || !sortKeys.isEmpty else {
            setQueryTask(nil)
            setQueryRunning(false)
            setDisplayKeys(nil)
            refreshPage()
            return
        }
        let title = sortKeys.isEmpty || !predicate.isTrivial
            ? String(localized: "Filtering…")
            : String(localized: "Sorting…")
        let activityID = beginActivity(title: title, isMutation: false)
        let reporter = progressReporter(for: activityID)
        setQueryRunning(true)
        let sortShare = sortKeys.isEmpty ? 0.0 : (predicate.isTrivial ? 1.0 : 0.5)
        setQueryTask(Task { [weak self] in
            do {
                let matcher = TabularRowMatcher(predicate: predicate)
                let rows = try await TabularScanEngine.matchingRows(in: table, matcher: matcher) { fraction in
                    reporter(fraction * (1 - sortShare))
                }
                var keys = rows.map { table.key(atRow: $0) }
                if !sortKeys.isEmpty {
                    keys = try await TabularSorter.sortedKeys(keys, in: table, by: sortKeys) { fraction in
                        reporter(1 - sortShare + fraction * sortShare)
                    }
                }
                self?.finishQuery(keys: keys, revision: revision, snapshot: table, activityID: activityID)
            } catch {
                self?.abandonQuery(revision: revision, activityID: activityID, error: error)
            }
        })
    }

    private func finishQuery(keys: [Int], revision: Int, snapshot: TabularTable, activityID: UUID) {
        endActivity(activityID)
        guard isCurrentQuery(revision), let table else { return }
        setQueryRunning(false)
        var resolved = keys
        if table.generation != snapshot.generation {
            let current = Set(table.rowOrder.keys)
            resolved = keys.filter { current.contains($0) }
            let known = Set(snapshot.rowOrder.keys)
            let added = table.rowOrder.keys.filter { !known.contains($0) }
            resolved.append(contentsOf: added)
        }
        setDisplayKeys(resolved)
        refreshPage()
    }

    private func abandonQuery(revision: Int, activityID: UUID, error: Error) {
        endActivity(activityID)
        guard isCurrentQuery(revision) else { return }
        setQueryRunning(false)
        if !(error is CancellationError) {
            Self.logger.error("Data file query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func currentPredicate() -> TabularRowPredicate {
        var parts: [TabularRowPredicate] = []
        let filters = filterState.appliedFilters.compactMap(cellPredicate(for:))
        if !filters.isEmpty {
            switch filterState.filterLogicMode {
            case .and:
                parts.append(.all(filters))
            case .or:
                parts.append(.any(filters))
            }
        }
        let search = trimmedSearchText
        if !search.isEmpty {
            let hidden = columnLayout.hiddenColumns
            let columns = zip(columnNames.ids, columnNames.displayNames)
                .filter { !hidden.contains($0.1) }
                .map(\.0)
            parts.append(.search(TabularSearch(text: search, columns: columns)))
        }
        switch parts.count {
        case 0: return .always
        case 1: return parts[0]
        default: return .all(parts)
        }
    }

    func cellPredicate(for filter: TableFilter) -> TabularRowPredicate? {
        guard !filter.isRawSQL, let id = columnNames.id(forName: filter.columnName) else { return nil }
        let kind = kind(of: id)
        let allowsNull = allowsNullLiterals && kind != .text
        return .cell(TabularCellPredicate(
            column: id,
            comparison: DataFileFilterMapping.comparison(for: filter.filterOperator),
            valueKind: kind.valueKind,
            operand: DataFileFilterMapping.operand(filter.value, allowsNullLiteral: allowsNull),
            secondOperand: DataFileFilterMapping.operand(filter.secondValue ?? "", allowsNullLiteral: allowsNull),
            listOperands: DataFileFilterMapping.listItems(filter.value).map {
                DataFileFilterMapping.operand($0, allowsNullLiteral: allowsNull)
            },
            isCaseSensitive: filter.filterOperator.supportsCaseSensitivity && filter.isCaseSensitive
        ))
    }

    func currentSortKeys() -> [TabularSortKey] {
        sortState.columns.compactMap { column in
            guard columnNames.ids.indices.contains(column.columnIndex) else { return nil }
            let id = columnNames.ids[column.columnIndex]
            return TabularSortKey(
                column: id,
                ascending: column.direction == .ascending,
                numeric: kind(of: id).sortsNumerically
            )
        }
    }
}
