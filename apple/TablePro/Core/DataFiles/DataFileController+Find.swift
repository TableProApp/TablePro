//
//  DataFileController+Find.swift
//  TablePro
//

import Foundation
import TableProTabular
import TableProTabularIO

// The window's Find menu items land on the grid's model, which owns the bar. Its search and replace
// cover the whole file through the methods below, not only the loaded page.
extension DataFileController {
    func showFind(replacing: Bool) {
        gridModel.showFind(replace: replacing)
    }

    func hideFind() {
        gridModel.hideFind()
    }

    func findNext() {
        gridModel.findNext()
    }

    func findPrevious() {
        gridModel.findPrevious()
    }

    func useSelectionForFind() {
        gridModel.useSelectionForFind()
    }

    func scopeFind(to column: TabularColumnID) {
        guard let id = findColumns.first(where: { $0.tabular == column })?.grid else { return }
        gridModel.findInColumn(id, replace: true)
    }

    // MARK: - Whole file

    func findMatches(_ query: GridDatasetFindQuery) async throws -> [GridFindState.Match] {
        guard let table, let tabularQuery = tabularFindQuery(for: query) else { return [] }
        let gridIDs = Dictionary(findColumns.map { ($0.tabular, $0.grid) }, uniquingKeysWith: { first, _ in first })
        let keys = visibleKeys()
        // A running mutation keeps the activity, so its progress and busy state stay on screen.
        let activityID = activity?.isMutation == true
            ? nil
            : beginActivity(title: String(localized: "Finding…"), isMutation: false)
        defer {
            if let activityID {
                endActivity(activityID)
            }
        }
        let progress: @Sendable (Double) -> Void
        if let activityID {
            progress = progressReporter(for: activityID)
        } else {
            progress = { _ in }
        }
        let found = try await TabularFinder.findAll(tabularQuery, keys: keys, in: table, progress: progress)
        return found.compactMap { match in
            gridIDs[match.column].map { GridFindState.Match(rowID: .existing(match.key), columnID: $0) }
        }
    }

    func replaceMatch(_ match: GridFindState.Match, query: GridDatasetFindQuery, with template: String) -> Bool {
        guard isEditable, !hasMutationInFlight,
              case .existing(let key) = match.rowID,
              let table,
              let id = findColumns.first(where: { $0.grid == match.columnID })?.tabular,
              let column = table.column(id),
              let tabularQuery = tabularFindQuery(for: query),
              let matcher = try? TabularFindMatcher(tabularQuery) else { return false }
        let original = table.cell(key: key, column: column)
        guard !original.kind.isNullLike else { return false }
        let replaced = matcher.replacing(in: original.text, with: template)
        guard replaced.replacements > 0, replaced.text != original.text else { return false }
        var updated = table
        updated.setCells([(key: key, columnID: id, cell: editedCell(replaced.text, replacing: original, column: id))])
        commit(updated, actionName: String(localized: "Replace"))
        return true
    }

    func replaceAll(_ query: GridDatasetFindQuery, with template: String) {
        guard let tabularQuery = tabularFindQuery(for: query) else { return }
        let keys = visibleKeys()
        runMutation(title: String(localized: "Replacing…"), actionName: String(localized: "Replace All")) { table, progress in
            let result = try await TabularFinder.replaceAll(tabularQuery, with: template, keys: keys, in: table, progress: progress)
            let message = GridFindEngine.replacementMessage(replacements: result.replacements, cells: result.changedCells)
            guard result.changedCells > 0 else {
                return DataFileMutationOutcome(table: nil, message: message)
            }
            return DataFileMutationOutcome(table: Self.applying(result.values, to: table), message: message)
        }
    }

    // The grid names a column by its display name, the table by its id.
    private var findColumns: [(grid: DataGridColumnID, tabular: TabularColumnID)] {
        zip(DataGridColumnSet.columnIDs(for: columnNames.displayNames), columnNames.ids).map { (grid: $0, tabular: $1) }
    }

    private func tabularFindQuery(for query: GridDatasetFindQuery) -> TabularFindQuery? {
        let tabularIDs = Dictionary(findColumns.map { ($0.grid, $0.tabular) }, uniquingKeysWith: { first, _ in first })
        let columns = query.columns.compactMap { tabularIDs[$0] }
        guard !columns.isEmpty else { return nil }
        return TabularFindQuery(
            text: query.term,
            matchesCase: query.options.matchesCase,
            matchesWholeWords: query.options.matchesWholeWord,
            isRegularExpression: query.options.usesRegularExpression,
            columns: columns
        )
    }
}
