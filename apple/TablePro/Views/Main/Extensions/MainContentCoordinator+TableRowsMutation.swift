//
//  MainContentCoordinator+TableRowsMutation.swift
//  TablePro
//
//  Single mutation surface for the active ResultSet's TableRows. Mutations
//  flow through the store; the per-ResultSet snapshot is only refreshed when
//  the user switches result sets (save outgoing, load incoming) so editing
//  one tab doesn't trigger an `@Observable` re-render of the whole editor.
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    @discardableResult
    func mutateActiveTableRows(
        for tabId: UUID,
        _ mutate: (inout TableRows) -> Delta
    ) -> Delta {
        let delta = tabSessionRegistry.updateTableRows(for: tabId, mutate)
        applyGridDelta(delta, forTab: tabId)
        return delta
    }

    func setActiveTableRows(
        _ tableRows: TableRows,
        for tabId: UUID,
        viewport intent: GridReloadIntent = .firstRow,
        source: ResultSourceChange = .newSource
    ) {
        let keepsViewState = source.keepsViewState
        let keyColumns = viewportKeyColumns(forTab: tabId)
        let gridIsMounted = isGridMounted(forTab: tabId, acceptsQueryTab: keepsViewState)
        let snapshot = gridIsMounted
            ? viewportSnapshot(forTab: tabId, intent: intent, keepsSelection: keepsViewState, keyColumns: keyColumns)
            : .top
        installTableRows(tableRows, for: tabId)
        if keepsViewState {
            carryValueFilter(onto: tableRows.columns, forTab: tabId)
            resetSelection(tabId: tabId)
        } else {
            resetViewStateForNewSource(tabId: tabId)
        }
        // Staged before the model reloads: the mounted grid applies it, selection included, on that reload.
        if gridIsMounted {
            let placement = GridViewportResolver.placement(
                for: intent,
                from: snapshot,
                in: tableRows,
                displayIDs: resolvedDisplayIDs(of: tableRows, forTab: tabId),
                keyColumns: keyColumns
            )
            tabSessionRegistry.stageViewportPlacement(placement, for: tabId)
        }
        if !tableRows.rows.isEmpty {
            clearRestoredRowAnchor(forTab: tabId)
        }
        notifyFullReplace(tabId: tabId)
    }

    // The order the incoming rows will show in, before the model has reloaded onto them.
    private func resolvedDisplayIDs(of tableRows: TableRows, forTab tabId: UUID) -> [RowID]? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.valueFilter.isActive else { return nil }
        return GridDisplayOrderResolver.resolve(
            tableRows: tableRows,
            valueFilter: tab.valueFilter,
            displayFormats: dataGridEntries[tabId]?.store.displayFormats ?? displayFormats(for: tab),
            databaseType: connection.type
        )
    }

    // Mode reconciliation lives here: a result switch or re-seed strands a Map tab like a fresh run does. Edits never change modes.
    private func installTableRows(_ tableRows: TableRows, for tabId: UUID) {
        tabSessionRegistry.setTableRows(tableRows, for: tabId)
        let spatialColumns = SpatialColumn.columns(in: tableRows)
        tabManager.mutate(tabId: tabId) { $0.display.spatialColumns = spatialColumns }
        reconcileResultsViewMode(against: tableRows, spatialColumns: spatialColumns, for: tabId)
    }

    // A mode leaving `availableModes` takes its segment and View menu items (no key equivalent), stranding the tab, as a non-SELECT does.
    private func reconcileResultsViewMode(
        against tableRows: TableRows,
        spatialColumns: [SpatialColumn],
        for tabId: UUID
    ) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabManager.tabs[index]
        let available = ResultsModeAvailability.modes(
            tabType: tab.tabType,
            hasTableName: tab.tableContext.tableName != nil,
            hasColumns: !tableRows.columns.isEmpty,
            hasSpatialColumn: !spatialColumns.isEmpty,
            hasServerOutput: !(tab.display.activeResultSet?.serverOutput.isEmpty ?? true)
        )
        let reconciled = ResultsModeAvailability.reconcile(
            tab.display.resultsViewMode,
            availableModes: available
        )
        guard reconciled != tab.display.resultsViewMode else { return }
        tabManager.mutate(tabId: tabId) { $0.display.resultsViewMode = reconciled }
    }

    // Same unsaved-changes gate as sorting: `handleColumnsChange` won't rebuild with pending edits, so the grid would write to the old table.
    func switchActiveResultSet(to resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[tabIdx].display.activeResultSetId != resultSetId else { return }

        confirmDiscardChangesIfNeeded(action: .resultSwitch) { [weak self] confirmed in
            guard confirmed else { return }
            self?.applyResultSetSwitch(to: resultSetId, in: tabId)
            self?.revealStatement(behind: resultSetId, in: tabId)
        }
    }

    // Only on the reader picking another result (HIG). Moves the caret without taking first responder, so focus stays put.
    private func revealStatement(behind resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[tabIdx].tabType == .query,
              let resultSetId,
              let anchor = tabManager.tabs[tabIdx].display.resultSets
                  .first(where: { $0.id == resultSetId })?.statementAnchor
        else { return }
        requestStatementJump(anchor, in: tabId)
    }

    // No discard gate: for callers that already decided the outgoing result is going away.
    func applyResultSetSwitch(to resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        flushBufferToActiveResult(tabId: tabId, pinnedOnly: false)
        tabManager.mutate(at: tabIdx) { $0.display.activeResultSetId = resultSetId }
        guard let incoming = tabManager.tabs[tabIdx].display.activeResultSet else { return }
        installTableRows(incoming.tableRows, for: tabId)
        resetViewStateForNewSource(tabId: tabId)
        syncLoadMoreState(from: incoming, at: tabIdx)
        adoptOrigin(of: incoming, at: tabIdx)
        notifyFullReplace(tabId: tabId)
    }

    // The shared buffer is the only copy page loads, Fetch All and edits write to, so hand it back before replacing it.
    func flushBufferToActiveResult(tabId: UUID, pinnedOnly: Bool) {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              let active = tabManager.tabs[idx].display.activeResultSet,
              !pinnedOnly || active.isPinned
        else { return }
        active.tableRows = tabSessionRegistry.tableRows(for: tabId)
    }

    // A plan or error result has no rows: left in the buffer, the previous rows get flushed into it and it renders as a grid.
    func seedBufferFromActiveResult(tabId: UUID) {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let rows = tabManager.tabs[idx].display.activeResultSet?.tableRows ?? TableRows()
        installTableRows(rows, for: tabId)
        resetViewStateForNewSource(tabId: tabId)
        notifyFullReplace(tabId: tabId)
    }

    // Rebuilds the change manager here, not via the `schemaVersion` observer, which refuses to run with unsaved edits (#2243).
    private func adoptOrigin(of resultSet: ResultSet, at tabIdx: Int) {
        guard tabManager.tabs[tabIdx].tabType == .query else { return }
        let origin = resultSet.origin
        tabManager.mutate(at: tabIdx) { tab in
            tab.tableContext.tableName = origin?.tableName
            tab.tableContext.schemaName = origin?.schemaName
            tab.tableContext.primaryKeyColumns = origin?.primaryKeyColumns ?? []
            tab.tableContext.isEditable = origin?.isEditable ?? false
            tab.tableContext.isView = origin?.isView ?? false
            tab.tableContext.objectType = origin?.objectType
            tab.tableContext.viewRowEditing = origin?.viewRowEditing
            tab.schemaVersion += 1
        }
        let tab = tabManager.tabs[tabIdx]
        guard tab.id == tabManager.selectedTabId else { return }
        let rows = tabSessionRegistry.tableRows(for: tab.id)
        changeManager.configureForTable(
            tableName: tab.tableContext.tableName ?? "",
            schemaName: tab.tableContext.schemaName,
            columns: resultSet.resultColumns,
            primaryKeyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: connection.type,
            generatedColumns: rows.generatedColumns,
            rowMatchPolicy: rows.rowMatchPolicy,
            columnTypeNames: rows.columnTypeNames
        )
    }

    // A value filter holds strings from the outgoing source, so it narrows an unrelated result to nothing; new rows carry no ORDER BY.
    private func resetViewStateForNewSource(tabId: UUID) {
        clearValueFilter(forTab: tabId)
        tabManager.mutate(tabId: tabId) { tab in
            guard tab.tabType == .query, !tab.sortState.columns.isEmpty else { return }
            tab.sortState = SortState()
        }
        resetSelection(tabId: tabId)
    }

    // Row ids are positional per page. A re-read of the same source restores the selection by key via the viewport placement.
    private func resetSelection(tabId: UUID) {
        if tabManager.tabs.first(where: { $0.id == tabId })?.selectionSnapshot.isEmpty == false {
            tabManager.mutate(tabId: tabId) { $0.selectionSnapshot = .empty }
        }
        guard let entry = dataGridEntries[tabId] else { return }
        entry.store.selectionSnapshot = .empty
        entry.model.clearSelection()
    }

    // A SQL Server batch result may have no single statement behind it, and re-running with ORDER BY would resend writes, so sort here.
    func sortHeldRows(by state: SortState, tabId: UUID) {
        confirmDiscardChangesIfNeeded(action: .sort) { [weak self] confirmed in
            guard let self, confirmed else { return }
            let rows = self.tabSessionRegistry.tableRows(for: tabId)
            let sorted = state.columns.isEmpty
                ? TableRowsSorting.inArrivalOrder(rows)
                : TableRowsSorting.sorted(rows, by: state)
            guard self.tabManager.mutate(tabId: tabId, { tab in
                tab.sortState = state
                tab.hasUserInteraction = true
            }) else { return }
            self.setActiveTableRows(sorted, for: tabId, source: .sameSource)
        }
    }

    private func syncLoadMoreState(from resultSet: ResultSet, at tabIdx: Int) {
        guard tabManager.tabs[tabIdx].tabType == .query else { return }
        tabManager.mutate(at: tabIdx) { tab in
            if resultSet.isTruncated {
                tab.pagination.hasMoreRows = true
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.setBaseQueryForMore(
                resultSet.baseQuery,
                parameterValues: resultSet.baseQueryParameterValues
            )
        }
    }

    private func notifyFullReplace(tabId: UUID) {
        let isSelected = tabManager.selectedTabId == tabId
        let tracer = TableLoadTracer.shared
        let token = isSelected ? tracer.applyingToken : nil
        if let token {
            tracer.stage(
                .gridReloadBegin,
                token: token,
                detail: "rows=\(tabSessionRegistry.tableRows(for: tabId).rows.count)"
            )
        }
        reloadGridModel(forTab: tabId)
        if let token { tracer.stage(.gridReloadEnd, token: token) }
    }
}
