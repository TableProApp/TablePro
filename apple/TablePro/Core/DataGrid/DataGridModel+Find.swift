import Foundation
import TableProPluginKit

// An owner holding more rows than the grid loaded (a data file's other pages) answers find for all of them.
// A match's rowID is the one its row carries once loaded; the owner calls findDatasetDidChange() when its rows change.
@MainActor
protocol DataGridDatasetFinding: AnyObject {
    // Every match in display order, row then column; progress and cancel go through the owner's activity UI.
    func gridFindAll(_ query: GridDatasetFindQuery) async throws -> [GridFindState.Match]
    func gridDisplayPosition(of rowID: RowID) -> Int?
    // Loads the row's page without selecting anything; false when the row is gone.
    func gridLoadRow(_ rowID: RowID) -> Bool
    // One undoable step; false when the cell no longer holds the term.
    func gridReplace(_ match: GridFindState.Match, query: GridDatasetFindQuery, with template: String) -> Bool
    // One undoable step over every match, with the owner's progress, cancel and outcome message.
    func gridReplaceAll(_ query: GridDatasetFindQuery, with template: String)
}

struct GridDatasetFindQuery: Equatable {
    // A literal term arrives trimmed, as the loaded-rows search trims it.
    let term: String
    let options: GridFindState.Options
    // In display order.
    let columns: [DataGridColumnID]
}

extension DataGridModel {
    var datasetFinder: (any DataGridDatasetFinding)? {
        get { find.datasetFinder }
        set { find.datasetFinder = newValue }
    }

    var canReplaceInFind: Bool {
        configuration.isEditable && actions != nil
    }

    // A dataset finder already searches every row.
    var findCoversPageOnly: Bool {
        datasetFinder == nil && dataSource?.gridHasUnloadedRows == true
    }

    var offersSearchAllRows: Bool {
        datasetFinder == nil && configuration.commands.contains(.searchAllRows) && actions != nil
    }

    var hasFindTerm: Bool {
        if find.options.usesRegularExpression { return !find.term.isEmpty }
        return !find.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canReplaceCurrentFindMatch: Bool {
        guard canReplaceInFind,
              let match = find.currentMatch,
              let column = columns.column(id: match.columnID) else { return false }
        return isColumnWritable(column)
    }

    // MARK: - Showing

    func showFind(replace: Bool = false) {
        if replace, canReplaceInFind {
            find.showsReplace = true
        }
        let wasVisible = find.isVisible
        find.isVisible = true
        if !wasVisible {
            refreshFind()
        }
    }

    func findInColumn(_ columnID: DataGridColumnID, replace: Bool = false) {
        find.options.columnScope = columnID
        if replace, canReplaceInFind {
            find.showsReplace = true
        }
        find.isVisible = true
        findQueryDidChange()
    }

    func hideFind() {
        guard find.isVisible else { return }
        find.reset()
        find.options.columnScope = nil
        find.showsReplace = false
        find.isVisible = false
        focus()
    }

    // MARK: - Searching

    // The term or an option changed: search again and select the first match from the cursor.
    func findQueryDidChange() {
        guard find.isVisible else { return }
        if datasetFinder != nil {
            searchDataset(revealsFirstMatch: true)
            return
        }
        let source = findSource
        let result = GridFindEngine.search(find.term, options: find.options, in: source)
        let current = GridFindEngine.index(
            atOrAfter: selection.activeCell,
            in: GridFindEngine.positions(of: result.matches, in: source)
        )
        find.setResults(result.matches, current: current, problem: result.problem)
        revealCurrentFindMatch()
    }

    // The rows changed under the bar: keep the current match when it survives and leave the selection alone.
    func refreshFind() {
        guard find.isVisible else { return }
        if datasetFinder != nil {
            // Another page changes the grid's rows, not the owner's; only another column set searches again.
            guard datasetFindQuery != find.datasetQuery else { return }
            searchDataset(revealsFirstMatch: false)
            return
        }
        let source = findSource
        let previous = find.currentMatch
        let result = GridFindEngine.search(find.term, options: find.options, in: source)
        let current: Int?
        if let previous, let kept = result.matches.firstIndex(of: previous) {
            current = kept
        } else {
            current = GridFindEngine.index(
                atOrAfter: selection.activeCell,
                in: GridFindEngine.positions(of: result.matches, in: source)
            )
        }
        find.setResults(result.matches, current: current, problem: result.problem)
    }

    // The owner's rows changed (an edit, an undo, a filter): search them again, keeping the current match.
    func findDatasetDidChange() {
        guard find.isVisible, datasetFinder != nil, find.datasetQuery != nil else { return }
        // One change can arrive in several calls; the search starts once the owner has finished it.
        find.deferDatasetSearch(Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            guard self.datasetFinder != nil, self.find.isVisible else {
                self.find.cancelDatasetSearch()
                return
            }
            self.searchDataset(revealsFirstMatch: false)
        })
    }

    func stopFindSearch() {
        find.stopDatasetSearch()
    }

    // Returns once no whole-dataset search is waiting or running.
    func findSearchSettled() async {
        while let task = find.datasetSearch {
            await task.value
            if find.datasetSearch == task { return }
        }
    }

    func findNext() {
        stepFind(forward: true)
    }

    func findPrevious() {
        stepFind(forward: false)
    }

    func useSelectionForFind() {
        let source = findSource
        guard let active = activeCell, let row = source.rows.row(withID: active.rowID) else { return }
        // A dataset finder matches the stored value, which the cell shows capped to one line.
        let shown = datasetFinder == nil
            ? GridFindEngine.searchableText(in: row, column: active.column, source: source)
            : storedText(in: row, column: active.column)
        guard let text = shown else { return }
        find.term = find.options.usesRegularExpression ? NSRegularExpression.escapedPattern(for: text) : text
        find.isVisible = true
        findQueryDidChange()
    }

    // The server matches the plain term in any column, ignoring case; any other option would change what it finds.
    var searchAllRowsKeepsTheOptions: Bool {
        find.options == GridFindState.Options()
    }

    func searchAllRows() {
        guard offersSearchAllRows, searchAllRowsKeepsTheOptions, let actions else { return }
        let term = find.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        hideFind()
        actions.gridSearchAllRows(term: term)
    }

    // MARK: - Replacing

    func replaceCurrentMatch() {
        guard canReplaceInFind, find.problem == nil, let match = find.currentMatch, commitEditing() else { return }
        if let finder = datasetFinder {
            replaceDatasetMatch(match, finder: finder)
            return
        }
        let source = findSource
        let replacement = GridFindEngine.replacements(
            for: [match],
            term: find.term,
            options: find.options,
            template: find.replacement,
            in: source,
            isWritable: { isColumnWritable($0) }
        )
        guard !replacement.edits.isEmpty else {
            findNext()
            return
        }
        let replaced = GridFindEngine.position(of: match, in: source)
        guard commit(replacement.edits, actionName: String(localized: "Replace")) else { return }
        refreshFind()
        guard !find.matches.isEmpty else { return }
        let positions = GridFindEngine.positions(of: find.matches, in: findSource)
        find.setCurrentIndex(replaced.flatMap { GridFindEngine.index(after: $0, in: positions) } ?? 0)
        revealCurrentFindMatch()
    }

    // Nil when nothing was committed here: a dataset finder commits and reports the outcome itself.
    // An empty replacement when every match sits where Replace cannot write.
    @discardableResult
    func replaceAllMatches() -> GridFindEngine.Replacement? {
        guard canReplaceInFind, commitEditing() else { return nil }
        if let finder = datasetFinder {
            replaceAllDatasetMatches(finder: finder)
            return nil
        }
        let source = findSource
        let result = GridFindEngine.search(find.term, options: find.options, in: source)
        guard result.problem == nil else { return nil }
        let replacement = GridFindEngine.replacements(
            for: result.matches,
            term: find.term,
            options: find.options,
            template: find.replacement,
            in: source,
            isWritable: { isColumnWritable($0) }
        )
        guard !replacement.edits.isEmpty else { return replacement }
        guard commit(replacement.edits, actionName: String(localized: "Replace All")) else { return nil }
        refreshFind()
        return replacement
    }

    // MARK: - Private

    private var findSource: GridFindEngine.Source {
        GridFindEngine.Source(
            rows: rows,
            order: order,
            columns: columns,
            displayFormats: store.displayFormats,
            databaseType: configuration.traits.databaseType,
            revealsInvisibleCharacters: AppSettingsManager.shared.dataGrid.showInvisibleCharacters
        )
    }

    private func stepFind(forward: Bool) {
        guard find.isVisible else { return }
        if let finder = datasetFinder {
            stepDatasetFind(finder, forward: forward)
            return
        }
        if find.matches.isEmpty {
            refreshFind()
        }
        guard !find.matches.isEmpty else { return }
        let index = GridFindEngine.step(
            from: find.currentIndex,
            active: selection.activeCell,
            positions: GridFindEngine.positions(of: find.matches, in: findSource),
            forward: forward
        )
        find.setCurrentIndex(index)
        revealCurrentFindMatch()
    }

    // The match becomes the active cell, so Copy, Return and the arrow keys act on the found column.
    private func revealCurrentFindMatch() {
        guard let match = find.currentMatch else { return }
        if displayIndex(of: match.rowID) == nil {
            guard let finder = datasetFinder, finder.gridLoadRow(match.rowID) else { return }
        }
        guard let row = displayIndex(of: match.rowID),
              let column = columns.displayPosition(of: match.columnID) else { return }
        selectCell(GridCoord(row: row, displayColumn: column))
        reveal(rowID: match.rowID, columnID: match.columnID)
    }

    private func storedText(in row: Row, column: DataGridColumn) -> String? {
        guard column.dataIndex < row.values.count,
              case .text(let text) = row.values[column.dataIndex],
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Dataset

    private var datasetFindQuery: GridDatasetFindQuery? {
        guard hasFindTerm else { return nil }
        let term = find.options.usesRegularExpression
            ? find.term
            : find.term.trimmingCharacters(in: .whitespacesAndNewlines)
        return GridDatasetFindQuery(
            term: term,
            options: find.options,
            columns: GridFindEngine.searchedColumns(options: find.options, in: findSource).map(\.id)
        )
    }

    private func searchDataset(revealsFirstMatch: Bool) {
        let query = datasetFindQuery
        let generation = find.beginDatasetSearch(query, clearsResults: revealsFirstMatch || query == nil)
        guard let query, !query.columns.isEmpty else {
            find.setResults([], current: nil, problem: nil)
            return
        }
        if let problem = GridFindEngine.problem(term: query.term, options: query.options) {
            find.setResults([], current: nil, problem: problem)
            return
        }
        find.attachDatasetSearch(Task { [weak self] in
            guard !Task.isCancelled, let finder = self?.datasetFinder else {
                self?.find.abandonDatasetSearch(generation: generation)
                return
            }
            do {
                let found = try await finder.gridFindAll(query)
                self?.finishDatasetSearch(found, generation: generation, revealsFirstMatch: revealsFirstMatch)
            } catch {
                self?.find.abandonDatasetSearch(generation: generation)
            }
        }, generation: generation)
    }

    private func finishDatasetSearch(_ found: [GridFindState.Match], generation: Int, revealsFirstMatch: Bool) {
        guard find.isCurrentDatasetSearch(generation) else { return }
        var current: Int?
        if let finder = datasetFinder, !found.isEmpty {
            let position = { (index: Int) in self.datasetPosition(of: found[index], finder: finder) }
            if let previous = find.currentMatch,
               let cell = datasetPosition(of: previous, finder: finder),
               let index = GridFindEngine.sortedIndex(atOrAfter: cell, count: found.count, position: position),
               found[index] == previous {
                current = index
            } else if let cursor = datasetCursor(finder) {
                current = GridFindEngine.sortedIndex(atOrAfter: cursor, count: found.count, position: position)
            } else {
                current = 0
            }
        }
        find.finishDatasetSearch(found, current: current, generation: generation)
        if revealsFirstMatch {
            revealCurrentFindMatch()
        }
    }

    private func stepDatasetFind(_ finder: any DataGridDatasetFinding, forward: Bool) {
        let matches = find.matches
        guard !matches.isEmpty else {
            // A search that finished empty stays empty until the owner reports a change.
            if !find.isSearching, find.searchStopped || datasetFindQuery != find.datasetQuery {
                searchDataset(revealsFirstMatch: true)
            }
            return
        }
        let count = matches.count
        let position = { (index: Int) in self.datasetPosition(of: matches[index], finder: finder) }
        let next: Int?
        if let active = selection.activeCell, currentFindMatchCell != active, let cursor = datasetCursor(finder) {
            next = forward
                ? GridFindEngine.sortedIndex(after: cursor, count: count, position: position)
                : GridFindEngine.sortedIndex(before: cursor, count: count, position: position)
        } else if let current = find.currentIndex {
            next = forward ? (current + 1) % count : (current - 1 + count) % count
        } else {
            next = forward ? 0 : count - 1
        }
        find.setCurrentIndex(next)
        revealCurrentFindMatch()
    }

    private func replaceDatasetMatch(_ match: GridFindState.Match, finder: any DataGridDatasetFinding) {
        guard let index = find.currentIndex,
              let query = datasetFindQuery,
              let column = columns.column(id: match.columnID),
              isColumnWritable(column) else { return }
        guard finder.gridReplace(match, query: query, with: find.replacement) else {
            findNext()
            return
        }
        // The owner's change searches again in the background; until then the list drops the replaced cell.
        find.removeMatch(at: index)
        revealCurrentFindMatch()
    }

    private func replaceAllDatasetMatches(finder: any DataGridDatasetFinding) {
        guard let query = datasetFindQuery,
              GridFindEngine.problem(term: query.term, options: query.options) == nil else { return }
        let writable = query.columns.filter { id in
            columns.column(id: id).map { isColumnWritable($0) } ?? false
        }
        guard !writable.isEmpty else { return }
        finder.gridReplaceAll(
            GridDatasetFindQuery(term: query.term, options: query.options, columns: writable),
            with: find.replacement
        )
    }

    private var currentFindMatchCell: GridCoord? {
        guard let match = find.currentMatch,
              let row = displayIndex(of: match.rowID),
              let column = columns.displayPosition(of: match.columnID) else { return nil }
        return GridCoord(row: row, displayColumn: column)
    }

    private func datasetPosition(of match: GridFindState.Match, finder: any DataGridDatasetFinding) -> GridCoord? {
        guard let row = finder.gridDisplayPosition(of: match.rowID),
              let column = columns.displayPosition(of: match.columnID) else { return nil }
        return GridCoord(row: row, displayColumn: column)
    }

    // The active cell in the owner's display order.
    private func datasetCursor(_ finder: any DataGridDatasetFinding) -> GridCoord? {
        guard let active = selection.activeCell,
              let rowID = rowID(at: active.row),
              let row = finder.gridDisplayPosition(of: rowID) else { return nil }
        return GridCoord(row: row, displayColumn: active.displayColumn)
    }
}
