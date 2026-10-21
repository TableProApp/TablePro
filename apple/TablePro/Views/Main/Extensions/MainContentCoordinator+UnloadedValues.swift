//
//  MainContentCoordinator+UnloadedValues.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

private let unloadedValuesLog = Logger(subsystem: "com.TablePro", category: "UnloadedValues")

extension MainContentCoordinator {
    func unloadedValueReader(for tab: QueryTab, lease: DriverLeaseOwner = DriverLeaseOwner()) -> UnloadedValueReader? {
        guard tab.tabType == .table,
              let tableName = tab.tableContext.tableName,
              !tab.tableContext.primaryKeyColumns.isEmpty,
              let scope = scope(for: tab) else { return nil }
        let builder = queryBuilder
        return UnloadedValueReader(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            keyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: connection.type,
            parameterStyle: PluginMetadataRegistry.shared.snapshot(for: connection.type)?.parameterStyle ?? .questionMark,
            quote: { builder.quoteIdentifier($0) },
            run: { [weak self] statement in
                guard let self else { throw CancellationError() }
                return try await self.withExecutionDriver(
                    scope: scope,
                    isTableTab: true,
                    lease: lease
                ) { driver in
                    try await driver.executeUserQuery(
                        query: statement.sql,
                        rowCap: nil,
                        parameters: statement.parameters
                    ).rows
                }
            }
        )
    }

    // False while the rows' unloaded values load; `retry` runs once every one has arrived.
    func unloadedValuesAreLoaded(
        displayRows: Set<Int>,
        columns: IndexSet? = nil,
        retry: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let tab = tabManager.selectedTab else { return true }
        let positions = displayRows.sorted()
        let shownIDs = shownRowIDs(at: positions, tabId: tab.id)
        let rows = tabSessionRegistry.tableRows(for: tab.id)
        let ids = shownIDs.compactMap { $0 }
            .filter { id in rows.row(withID: id)?.unloadedColumns.keys.contains { columns?.contains($0) ?? true } == true }
        guard !ids.isEmpty else { return true }
        let tabId = tab.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await self.loadUnloadedValues(tabId: tabId, rowIDs: ids, columns: columns)
            guard loaded, self.tabManager.selectedTabId == tabId,
                  self.shownRowIDs(at: positions, tabId: tabId) == shownIDs else {
                NSSound.beep()
                return
            }
            retry()
        }
        return false
    }

    private func shownRowIDs(at positions: [Int], tabId: UUID) -> [RowID?] {
        let rows = tabSessionRegistry.tableRows(for: tabId)
        let displayIDs = activeGridDisplayIDs
        return positions.map { DisplayRowMapping.row(forDisplay: $0, displayIDs: displayIDs, in: rows)?.id }
    }

    func loadInspectorRowValues(tabId: UUID, displayRow: Int) async {
        guard tabManager.selectedTabId == tabId,
              let row = DisplayRowMapping.row(
                  forDisplay: displayRow,
                  displayIDs: activeGridDisplayIDs,
                  in: tabSessionRegistry.tableRows(for: tabId)
              ),
              row.hasUnloadedValues else { return }
        await loadUnloadedValues(tabId: tabId, rowIDs: [row.id])
    }

    @discardableResult
    func loadUnloadedValues(tabId: UUID, rowIDs: [RowID], columns: IndexSet? = nil) async -> Bool {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return false }
        let tableRows = tabSessionRegistry.tableRows(for: tabId)
        let rows = rowIDs.compactMap { tableRows.row(withID: $0) }.filter(\.hasUnloadedValues)
        guard !rows.isEmpty else { return true }
        let lease = DriverLeaseOwner()
        guard let reader = unloadedValueReader(for: tab, lease: lease) else { return false }

        let epoch = tabExecution.contentEpoch(for: tabId)
        let resultId = tab.display.activeResultSetId
        let workToken = tabExecution.beginUnclaimedWork(for: tabId)
        defer { tabExecution.endUnclaimedWork(workToken, for: tabId) }

        // Installed as the tab's query task, unless a page load holds it, so Stop cancels the read.
        let outcome = UnloadedValueReadOutcome()
        let readTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                outcome.result = .success(try await self.readUnloadedValues(
                    of: rows, columns: columns, tableColumns: tableRows.columns, reader: reader
                ))
            } catch {
                outcome.result = .failure(error)
            }
        }
        let owner = TabQueryTaskOwner.unclaimedWork(tabId: tabId, token: workToken)
        let ownsStop = !queryTasks.hasTask(for: tabId)
        if ownsStop { installQueryTask(readTask, owner: owner, lease: lease) }
        await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }
        if ownsStop { retireQueryTask(owner) }

        let read: UnloadedValueRead
        do {
            guard let result = outcome.result, !readTask.isCancelled else { return false }
            read = try result.get()
        } catch {
            unloadedValuesLog.error("Loading values failed: \(error.publicLogShape, privacy: .public)")
            if !DatabaseCancellationDiagnosis.isCancellation(error) {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could Not Load Value"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
            }
            return false
        }

        guard tabExecution.isSameContent(epoch, for: tabId),
              tabManager.tabs.first(where: { $0.id == tabId })?.display.activeResultSetId == resultId else {
            return false
        }
        mutateActiveTableRows(for: tabId) { $0.fillUnloaded(read.values) }
        if tabManager.selectedTabId == tabId {
            changeManager.adoptLoadedValues(read.values)
            repaintFilledCells(read.values, tabId: tabId)
        }
        inspectorRowSourceRevision &+= 1
        return read.isComplete
    }

    // Reads values without putting them in the grid, for Export Results, which streams them out.
    func unloadedValueFill(for tab: QueryTab) -> UnloadedValueFill? {
        guard let reader = unloadedValueReader(for: tab) else { return nil }
        let tableColumns = tabSessionRegistry.tableRows(for: tab.id).columns
        return { [weak self] rows in
            guard let self else { throw CancellationError() }
            let read = try await self.readUnloadedValues(
                of: rows, columns: nil, tableColumns: tableColumns, reader: reader
            )
            guard read.isComplete else { throw UnloadedValueError.rowsNotFound }
            return read.values
        }
    }

    private func readUnloadedValues(
        of rows: [Row],
        columns: IndexSet?,
        tableColumns: [String],
        reader: UnloadedValueReader
    ) async throws -> UnloadedValueRead {
        let pending = rows.compactMap { row -> (row: Row, columns: [Int])? in
            let unloaded = row.unloadedColumns.keys.filter { columns?.contains($0) ?? true }.sorted()
            return unloaded.isEmpty ? nil : (row, unloaded)
        }
        guard !pending.isEmpty else { return UnloadedValueRead() }

        let keyIndices = reader.keyColumns.compactMap { tableColumns.firstIndex(of: $0) }
        guard keyIndices.count == reader.keyColumns.count else { return UnloadedValueRead(isComplete: false) }
        let wanted = Array(Set(pending.flatMap(\.columns))).sorted()

        var requests: [UnloadedValueReader.Request] = []
        var keyByRow: [RowID: [PluginCellValue]] = [:]
        for entry in pending {
            let key = keyIndices.map { storedValue(of: entry.row, column: $0) }
            guard !key.contains(where: \.isNull) else { continue }
            keyByRow[entry.row.id] = key
            let bytes = entry.columns.reduce(0) { $0 + (entry.row.unloadedColumns[$1] ?? 0) }
            requests.append(UnloadedValueReader.Request(key: key, byteCount: bytes))
        }

        let fetched = try await reader.read(columns: wanted.map { tableColumns[$0] }, requests: requests)
        var read = UnloadedValueRead()
        for entry in pending {
            guard let key = keyByRow[entry.row.id], let values = fetched[key] else {
                read.isComplete = false
                continue
            }
            for column in entry.columns {
                guard let position = wanted.firstIndex(of: column), position < values.count else { continue }
                read.values[entry.row.id, default: [:]][column] = values[position]
            }
        }
        return read
    }

    // The fill reports storage positions, and the grid reads a delta's rows as display positions.
    private func repaintFilledCells(_ values: [RowID: [Int: PluginCellValue]], tabId: UUID) {
        let rows = tabSessionRegistry.tableRows(for: tabId)
        let displayIDs = activeGridDisplayIDs
        var positions: Set<CellPosition> = []
        for (id, cells) in values {
            guard let displayRow = DisplayRowMapping.displayIndex(forRowID: id, displayIDs: displayIDs, in: rows) else {
                continue
            }
            for column in cells.keys {
                positions.insert(CellPosition(row: displayRow, column: column))
            }
        }
        guard !positions.isEmpty else { return }
        dataTabDelegate?.tableViewCoordinator?.applyDelta(.cellsChanged(positions))
    }

    func rowsWithUnloadedValues() -> Set<RowID> {
        guard let tabId = tabManager.selectedTab?.id else { return [] }
        return Set(tabSessionRegistry.tableRows(for: tabId).rows.lazy.filter(\.hasUnloadedValues).map(\.id))
    }

    // The server holds the row under its key as last read, not as a pending edit has it.
    private func storedValue(of row: Row, column: Int) -> PluginCellValue {
        let pendingUpdate = changeManager.rowChanges.first { $0.rowID == row.id && $0.type == .update }
        if let change = pendingUpdate?.cellChanges.first(where: { $0.columnIndex == column }) {
            return change.oldValue
        }
        return row[column]
    }
}

@MainActor
private final class UnloadedValueReadOutcome {
    var result: Result<UnloadedValueRead, Error>?
}
