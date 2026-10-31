//
//  DataGridViewController+Changes.swift
//  TablePro
//

import AppKit

extension DataGridViewController {
    // Drawn rows repaint through needsDisplay; reloadData(forRowIndexes:columnIndexes:) only mounts and unmounts a
    // cell view, because reloading an edited row ends the edit (probe P1d, P2).
    func apply(_ change: DataGridChange) {
        editingWillApply(change)
        // AppKit adjusts and announces its own selection on an insert or removal; the model's selection is the one that counts.
        isMirroringSelection = true
        switch change {
        case .reload:
            reloadAll()
            applyStagedViewport()
        case .columnsChanged:
            columnsDidChange()
        case .rowsInserted(let indexes):
            insertRows(indexes)
        case .rowsRemoved(let indexes):
            removeRows(indexes)
        case .rowsUpdated(let rows, let columns):
            updateRows(rows, columns: columns)
        }
        // A moved row view keeps its layer's pixels, and its number and stripe come from the index it now holds.
        redrawRows(change.movedRows(rowCount: model.rowCount))
        isMirroringSelection = false
        mirrorSelection()
        editingDidApply(change)
        selectionDidMove()
        selectionSummaryTracker.dataDidChange()
    }

    func configurationDidChange() {
        applyTableSettings()
        let changed = presenter.refreshColumnPresentations()
        reconcileColumns(widening: changed)
        applyRowNumberWidth()
        syncSortIndicators()
        redrawVisibleRows()
        updateFittingHeight()
    }

    // MARK: - Structural changes

    func reloadAll() {
        presenter.rebuildVisualIndex()
        let changed = presenter.refreshColumnPresentations()
        reconcileColumns(widening: changed)
        applyRowNumberWidth()
        for pane in panes {
            pane.tableView.reloadData()
        }
        drawnSelection = model.selection
        // A view-based reloadData() drops the selection without telling anyone (probe P2), so it is written back.
        mirrorSelection()
        updateHighlightedColumns(model.selection)
        syncSortIndicators()
        startBackgroundPrewarm()
        updateFittingHeight()
    }

    private func columnsDidChange() {
        presenter.rebuildVisualIndex()
        let changed = presenter.refreshColumnPresentations()
        reconcileColumns(widening: changed)
        applyRowNumberWidth()
        drawnSelection = model.selection
        updateHighlightedColumns(model.selection)
        syncSortIndicators()
        redrawVisibleRows()
        remountAccessibilityCells(force: true)
    }

    // Both panes take the same insert in one call, so their document heights never differ.
    private func insertRows(_ indexes: IndexSet) {
        let target = model.rowCount
        guard !indexes.isEmpty,
              panes.allSatisfy({ $0.tableView.numberOfRows + indexes.count == target }) else {
            reloadAll()
            return
        }
        presenter.rebuildVisualIndex()
        for pane in panes {
            pane.tableView.insertRows(at: indexes, withAnimation: [])
        }
        applyRowNumberWidth()
        startBackgroundPrewarm()
        updateFittingHeight()
    }

    private func removeRows(_ indexes: IndexSet) {
        let target = model.rowCount
        guard !indexes.isEmpty,
              panes.allSatisfy({ $0.tableView.numberOfRows - indexes.count == target }) else {
            reloadAll()
            return
        }
        presenter.rebuildVisualIndex()
        for pane in panes {
            pane.tableView.removeRows(at: indexes, withAnimation: [])
        }
        applyRowNumberWidth()
        updateFittingHeight()
    }

    private func updateRows(_ rows: IndexSet, columns displayColumns: IndexSet?) {
        let wholeRows = refreshRowState(rows, columns: displayColumns)
        for pane in panes {
            let table = pane.tableView
            let rects = (displayColumns ?? []).compactMap {
                pane.tableIndex(forDisplayPosition: $0, columns: model.columns).map(table.rect(ofColumn:))
            }
            table.enumerateAvailableRowViews { rowView, row in
                guard rows.contains(row), let rowView = rowView as? DataGridRowView else { return }
                if wholeRows.contains(row) {
                    rowView.redrawCells()
                } else {
                    rects.forEach(rowView.redrawCells(inTableRect:))
                }
            }
        }
    }

    // Updates the rows' pending marks and answers which drawn rows repaint whole: a row tint and the row number span
    // both panes, so only a row whose tint cannot have changed keeps to the changed columns.
    func refreshRowState(_ rows: IndexSet, columns displayColumns: IndexSet?) -> IndexSet {
        let current = model.rows
        let drawn = rowsWithViews(in: rows)
        let tintsBefore = drawn.map { rowTint(forRow: $0) }
        presenter.updateVisualIndex(for: rows.compactMap { model.order.rowID(at: $0, in: current) })
        // The model drops a changed row's cached highlight before this runs, so a row rule's old wash is not known.
        guard displayColumns != nil, !hasRowHighlightRules else { return drawn }
        var retinted = IndexSet()
        for (row, before) in zip(drawn, tintsBefore) where rowTint(forRow: row) != before {
            retinted.insert(row)
        }
        return retinted
    }

    private var hasRowHighlightRules: Bool {
        model.dataSource?.gridHighlightRules.contains { $0.isEnabled && $0.target == .row } ?? false
    }

    private func rowsWithViews(in rows: IndexSet) -> IndexSet {
        var drawn = IndexSet()
        for pane in panes {
            pane.tableView.enumerateAvailableRowViews { _, row in
                if rows.contains(row) {
                    drawn.insert(row)
                }
            }
        }
        return drawn
    }

    // MARK: - Geometry

    // The setting is a floor under the grid font's line height; both panes take it in one call.
    func applyRowHeight() {
        let height = DataGridMetrics.rowHeight(
            AppSettingsManager.shared.dataGrid.rowHeight,
            font: ThemeEngine.shared.dataGridFonts.regular
        )
        guard panes.contains(where: { $0.tableView.rowHeight != height }) else { return }
        keepingFirstVisibleRow {
            for pane in panes {
                pane.tableView.rowHeight = height
                pane.tableView.tile()
            }
        }
        updateFittingHeight()
    }

    // The table's own header, rows and legacy scroller: what a fitsRows grid needs to show every row.
    var measuredFittingHeight: CGFloat {
        let table = main.tableView
        return DataGridMetrics.fittingHeight(
            headerHeight: table.headerView?.frame.height ?? 0,
            rowCount: table.numberOfRows,
            rowPitch: table.rowHeight + table.intercellSpacing.height,
            horizontalScrollerHeight: main.scrollView.legacyHorizontalScrollerHeight
        )
    }

    // Published on the next turn: this runs inside SwiftUI updates and layout passes, which refuse a model change.
    func updateFittingHeight() {
        guard model.configuration.fitsRows, !isFittingHeightScheduled,
              measuredFittingHeight != model.fittingHeight else { return }
        isFittingHeightScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFittingHeightScheduled = false
            guard self.model.mountedView === self, self.model.configuration.fitsRows else { return }
            self.model.setFittingHeight(self.measuredFittingHeight)
        }
    }

    // The clip view keeps its offset in points, so a new row height would otherwise bring other rows into view.
    private func keepingFirstVisibleRow(_ change: () -> Void) {
        let table = main.tableView
        guard let sample = viewportSample(), table.rowHeight > 0 else {
            change()
            return
        }
        let previousHeight = table.rowHeight
        change()
        let offset = sample.offset * table.rowHeight / previousHeight
        let rowOrigin = table.rect(ofRow: sample.row).minY
        let x = main.scrollView.contentView.bounds.origin.x
        table.scroll(NSPoint(x: x, y: rowOrigin + offset - headerInset))
    }

    var headerInset: CGFloat {
        main.scrollView.contentView.contentInsets.top
    }

    func viewportSample() -> (row: Int, offset: CGFloat)? {
        let table = main.tableView
        guard table.numberOfRows > 0 else { return nil }
        var visible = table.visibleRect
        visible.origin.y += headerInset
        visible.size.height = max(0, visible.height - headerInset)
        let rows = table.rows(in: visible)
        guard rows.length > 0, rows.location < table.numberOfRows else { return nil }
        let offset = visible.minY - table.rect(ofRow: rows.location).minY
        return (rows.location, max(0, offset))
    }

    // MARK: - Viewport anchor

    func saveViewportAnchor() {
        guard let sample = viewportSample(), let rowID = model.rowID(at: sample.row) else { return }
        model.store.viewportAnchor = GridViewportPlacement(
            firstVisibleRow: rowID,
            firstVisibleOffset: sample.offset,
            selectedRows: [],
            revealsSelection: false
        )
    }

    // A placement is one-shot: staged by the owner before a reload, or saved here on the way out.
    func applyStagedViewport() {
        guard let placement = model.store.viewportAnchor else { return }
        guard main.scrollView.contentView.bounds.height > 0 else {
            needsViewportRestore = true
            return
        }
        model.store.viewportAnchor = nil
        let table = main.tableView
        let x = main.scrollView.contentView.bounds.origin.x
        if let rowID = placement.firstVisibleRow,
           let row = model.displayIndex(of: rowID),
           row < table.numberOfRows {
            table.scroll(NSPoint(x: x, y: table.rect(ofRow: row).minY + placement.firstVisibleOffset - headerInset))
        } else {
            table.scroll(NSPoint(x: x, y: -headerInset))
        }
        guard !placement.selectedRows.isEmpty else { return }
        // Selecting publishes the model, which a SwiftUI update or layout pass refuses, so it runs on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.mountedView === self else { return }
            self.model.selectRows(placement.selectedRows)
            guard placement.revealsSelection, let row = self.model.selection.affectedRows.first else { return }
            self.reveal(row: row, displayColumn: nil)
        }
    }

    // MARK: - Prewarm

    // Formats ±250 rows around the viewport in 2 ms slices, paused during live scroll, so a row draw is a cache hit.
    func startBackgroundPrewarm() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        prewarmTask?.cancel()
        prewarmTask = Task { @MainActor [weak self] in
            await self?.runBackgroundPrewarm()
        }
    }

    func pausePrewarm() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    func schedulePrewarmResume() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.startBackgroundPrewarm()
        }
    }

    private func runBackgroundPrewarm() async {
        var nextIndex: Int?
        let budget = Duration.milliseconds(2)
        while !Task.isCancelled {
            let rows = model.rows
            let order = model.order
            let formats = model.store.displayFormats
            let databaseType = model.configuration.traits.databaseType
            let visible = main.tableView.rows(in: main.tableView.visibleRect)
            let window = DataGridPrewarmWindow.rows(
                around: max(0, visible.location)..<max(0, visible.location + visible.length),
                displayCount: order.count(in: rows)
            )
            var index = max(nextIndex ?? window.lowerBound, window.lowerBound)
            guard index < window.upperBound else { return }

            let deadline = ContinuousClock.now.advanced(by: budget)
            while index < window.upperBound {
                if Task.isCancelled { return }
                if let row = order.row(at: index, in: rows) {
                    presenter.cacheText(of: row, rows: rows, formats: formats, databaseType: databaseType)
                }
                index += 1
                if ContinuousClock.now >= deadline { break }
            }
            nextIndex = index
            await Task.yield()
        }
    }

    func mainViewportDidMove() {
        remountAccessibilityCells()
        schedulePrewarmResume()
    }
}
