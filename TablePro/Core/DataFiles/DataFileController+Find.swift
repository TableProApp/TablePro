//
//  DataFileController+Find.swift
//  TablePro
//

import Foundation
import TableProTabular
import TableProTabularIO

struct DataFileFindMatch: Equatable, Hashable {
    let key: Int
    let column: TabularColumnID
}

struct DataFileFindState: Equatable {
    var isVisible = false
    var isReplaceVisible = false
    var text = ""
    var replacement = ""
    var matchesCase = false
    var matchesWholeWords = false
    var isRegularExpression = false
    var scopeColumn: TabularColumnID?
    var matches: [DataFileFindMatch] = []
    var currentIndex: Int?
    var isSearching = false
    var isPatternInvalid = false

    var hasQuery: Bool { !text.isEmpty }
}

extension DataFileController {
    func showFind(replacing: Bool) {
        find.isVisible = true
        if replacing, isEditable {
            find.isReplaceVisible = true
        }
        if find.hasQuery {
            runFind()
        }
    }

    func hideFind() {
        find = DataFileFindState(
            matchesCase: find.matchesCase,
            matchesWholeWords: find.matchesWholeWords,
            isRegularExpression: find.isRegularExpression
        )
        findTask?.cancel()
        gridCoordinator?.applyFindMatch(nil)
    }

    func scopeFind(to column: TabularColumnID) {
        find.scopeColumn = column
        showFind(replacing: true)
    }

    func scheduleFind() {
        findDebounceTask?.cancel()
        findDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.queryDebounce)
            guard !Task.isCancelled else { return }
            self?.runFind()
        }
    }

    func findQuery() -> TabularFindQuery {
        let hidden = columnLayout.hiddenColumns
        let columns: [TabularColumnID]
        if let scope = find.scopeColumn, columnNames.ids.contains(scope) {
            columns = [scope]
        } else {
            columns = zip(columnNames.ids, columnNames.displayNames).filter { !hidden.contains($0.1) }.map(\.0)
        }
        return TabularFindQuery(
            text: find.text,
            matchesCase: find.matchesCase,
            matchesWholeWords: find.matchesWholeWords,
            isRegularExpression: find.isRegularExpression,
            columns: columns
        )
    }

    func runFind() {
        findTask?.cancel()
        guard let table, find.hasQuery else {
            find.matches = []
            find.currentIndex = nil
            find.isPatternInvalid = false
            gridCoordinator?.applyFindMatch(nil)
            return
        }
        let query = findQuery()
        guard TabularFindMatcher.validate(query) else {
            find.isPatternInvalid = true
            find.matches = []
            find.currentIndex = nil
            gridCoordinator?.applyFindMatch(nil)
            return
        }
        find.isPatternInvalid = false
        find.isSearching = true
        let keys = visibleKeys()
        let activityID = beginActivity(title: String(localized: "Finding…"), isMutation: false)
        let reporter = progressReporter(for: activityID)
        findTask = Task { [weak self] in
            do {
                let found = try await TabularFinder.findAll(query, keys: keys, in: table, progress: reporter)
                let matches = found.map { DataFileFindMatch(key: $0.key, column: $0.column) }
                self?.finishFind(matches, activityID: activityID)
            } catch {
                self?.endActivity(activityID)
                if !(error is CancellationError) {
                    self?.find.isSearching = false
                }
            }
        }
    }

    private func finishFind(_ matches: [DataFileFindMatch], activityID: UUID) {
        endActivity(activityID)
        find.isSearching = false
        find.matches = matches
        find.currentIndex = matches.isEmpty ? nil : 0
        showCurrentMatch()
    }

    func findNext() {
        guard !find.matches.isEmpty else {
            runFind()
            return
        }
        find.currentIndex = ((find.currentIndex ?? -1) + 1) % find.matches.count
        showCurrentMatch()
    }

    func findPrevious() {
        guard !find.matches.isEmpty else {
            runFind()
            return
        }
        let count = find.matches.count
        find.currentIndex = ((find.currentIndex ?? 0) - 1 + count) % count
        showCurrentMatch()
    }

    func showCurrentMatch() {
        guard let index = find.currentIndex, find.matches.indices.contains(index) else {
            gridCoordinator?.applyFindMatch(nil)
            return
        }
        let match = find.matches[index]
        reveal(key: match.key, selecting: false)
        guard let pageRow = pageKeys.firstIndex(of: match.key), let column = columnNames.index(of: match.column) else {
            return
        }
        gridCoordinator?.applyFindMatch(FindMatch(displayRow: pageRow, columnIndex: column))
    }

    func useSelectionForFind() {
        guard let table, let cell = activeCell(), let column = table.column(cell.column) else { return }
        find.text = table.cell(key: cell.key, column: column).text
        showFind(replacing: false)
        runFind()
    }

    func replaceCurrent() {
        guard isEditable, let index = find.currentIndex, find.matches.indices.contains(index),
              let table, let matcher = try? TabularFindMatcher(findQuery()) else { return }
        let match = find.matches[index]
        guard let column = table.column(match.column) else { return }
        let original = table.cell(key: match.key, column: column)
        let replaced = matcher.replacing(in: original.text, with: find.replacement)
        guard replaced.replacements > 0 else {
            findNext()
            return
        }
        var updated = table
        updated.setCells([(key: match.key, columnID: match.column, cell: editedCell(replaced.text, replacing: original))])
        commit(updated, actionName: String(localized: "Replace"))
        find.matches.remove(at: index)
        find.currentIndex = find.matches.isEmpty ? nil : min(index, find.matches.count - 1)
        showCurrentMatch()
    }

    func replaceAll() {
        guard isEditable, find.hasQuery else { return }
        let query = findQuery()
        let template = find.replacement
        let keys = visibleKeys()
        runMutation(title: String(localized: "Replacing…"), actionName: String(localized: "Replace All")) { table, progress in
            let result = try await TabularFinder.replaceAll(query, with: template, keys: keys, in: table, progress: progress)
            guard result.changedCells > 0 else {
                return DataFileMutationOutcome(table: nil, message: String(localized: "No matches to replace."))
            }
            return DataFileMutationOutcome(
                table: Self.applying(result.values, to: table),
                message: Self.replacementMessage(replacements: result.replacements, cells: result.changedCells)
            )
        }
    }

    nonisolated static func replacementMessage(replacements: Int, cells: Int) -> String {
        String(
            format: String(localized: "Replaced %@ matches in %@ cells."),
            replacements.formatted(),
            cells.formatted()
        )
    }
}
