//
//  DataGridView+RowDecoration.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func refreshVisibleRowVisualStates() {
        guard let tableView else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? DataGridRowView)?.invalidateVisualState()
        }
    }

    func refreshRowVisualState(at row: Int) {
        guard let tableView,
              let dataRowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView
        else { return }
        dataRowView.invalidateVisualState()
    }

    @discardableResult
    func syncHighlightRules(_ rules: [HighlightRule], tableRows: TableRows) -> Bool {
        let key = HighlightRuleSet.Key(rules: rules, columns: tableRows.columns, columnTypes: tableRows.columnTypes)
        let compiledChanged = highlightRuleSet.key != key
        if compiledChanged {
            highlightRuleSet = HighlightRuleSet(
                rules: rules,
                columns: tableRows.columns,
                columnTypes: tableRows.columnTypes
            )
        }
        guard displayState.highlightRuleSetKey != key else { return compiledChanged }
        displayState.highlightRuleSetKey = key
        displayCache.clearHighlights()
        return true
    }

    func highlight(for row: Row) -> RowHighlight {
        guard !highlightRuleSet.isEmpty else { return .none }
        if let cached = displayCache.highlight(forID: row.id) { return cached }
        let resolved = highlightRuleSet.highlight(for: row.values)
        displayCache.setHighlight(resolved, forID: row.id)
        return resolved
    }

    func highlightDescription(row: Int, columnIndex: Int) -> String? {
        guard let rule = visualState(for: row).drawnHighlightRule(forColumn: columnIndex) else { return nil }
        return HighlightRuleDescription.condition(of: rule, valueLimit: HighlightRuleDescription.menuValueLimit)
    }

    func invalidateRowDecoration(displayRow row: Int) {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return }
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView {
            rowView.invalidateVisualState()
            rowView.redrawCells()
        }
        repaintRowGutter(forRow: row)
    }

    func repaintVisibleRowDecorations() {
        guard let tableView else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let dataRowView = rowView as? DataGridRowView else { return }
            dataRowView.invalidateVisualState()
            dataRowView.redrawCells()
        }
        repaintRowGutter()
    }

    private func repaintRowGutter(forRow row: Int) {
        guard let rowGutter, let tableView else { return }
        let band = rowGutter.convert(tableView.rect(ofRow: row), from: tableView)
        rowGutter.setNeedsDisplay(NSRect(x: 0, y: band.minY, width: rowGutter.bounds.width, height: band.height))
    }
}
