//
//  MainContentCoordinator+TabEdits.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import TableProPluginKit

// A tab's staged row edits and their undo history. They stay with the tab while another one is shown.
struct TabEdits {
    let changes: DataChangeManager
    let gridState: AnyChangeManager
    let undoManager: UndoManager
    let observers: [AnyCancellable]
}

// The selected tab's edits for the views that draw them: they follow the selection instead of holding one tab.
@MainActor
final class SelectedTabEdits: ObservableObject {
    private(set) var manager: DataChangeManager
    private var forwarding: AnyCancellable?

    init(_ manager: DataChangeManager) {
        self.manager = manager
        forwarding = forward(manager)
    }

    func follow(_ manager: DataChangeManager) {
        guard manager !== self.manager else { return }
        objectWillChange.send()
        self.manager = manager
        forwarding = forward(manager)
    }

    private func forward(_ manager: DataChangeManager) -> AnyCancellable {
        manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

extension MainContentCoordinator {
    // The selected tab's edits, which the window's commands act on.
    var changeManager: DataChangeManager {
        guard let tabId = tabManager.selectedTabId else { return idleChangeManager }
        return changeManager(forTab: tabId)
    }

    func changeManager(forTab tabId: UUID) -> DataChangeManager {
        edits(forTab: tabId).changes
    }

    func existingChangeManager(forTab tabId: UUID) -> DataChangeManager? {
        tabEdits[tabId]?.changes
    }

    func hasStagedRowEdits(inTab tabId: UUID) -> Bool {
        tabEdits[tabId]?.changes.hasChanges ?? false
    }

    func gridChangeState(forTab tabId: UUID) -> AnyChangeManager {
        edits(forTab: tabId).gridState
    }

    func rowOperations(forTab tabId: UUID) -> RowOperationsManager {
        RowOperationsManager(changeManager: changeManager(forTab: tabId))
    }

    // Edits made on a result name its rows, so a result that replaces it leaves them nothing to write to.
    func dropEdits(ofReplacedResultIn tabId: UUID) {
        existingChangeManager(forTab: tabId)?.clearChangesAndUndoHistory()
    }

    func releaseEdits(ofTab tabId: UUID) {
        guard let edits = tabEdits.removeValue(forKey: tabId) else { return }
        edits.changes.clearChangesAndUndoHistory()
        edits.changes.pluginDriver = nil
        guard selectedTabEdits.manager === edits.changes else { return }
        selectedTabEdits.follow(tabManager.selectedTabId == tabId ? idleChangeManager : changeManager)
    }

    func releaseEdits(exceptTabs openTabIds: Set<UUID>) {
        for tabId in tabEdits.keys where !openTabIds.contains(tabId) {
            releaseEdits(ofTab: tabId)
        }
    }

    func releaseAllTabEdits() {
        for tabId in Array(tabEdits.keys) {
            releaseEdits(ofTab: tabId)
        }
        selectedTabEdits.follow(idleChangeManager)
        idleChangeManager.clearChanges()
        idleChangeManager.pluginDriver = nil
        rowWriter = nil
    }

    func adoptRowWriter(_ writer: (any PluginDatabaseDriver)?) {
        rowWriter = writer
        for manager in [idleChangeManager] + tabEdits.values.map(\.changes) where manager.pluginDriver !== writer {
            manager.pluginDriver = writer
        }
    }

    // `$selectedTabId` publishes before the property changes, so the new id is the one it hands over.
    func followSelectedTabEdits() -> AnyCancellable {
        tabManager.$selectedTabId
            .removeDuplicates()
            .sink { [weak self] tabId in
                guard let self else { return }
                selectedTabEdits.follow(tabId.map { self.changeManager(forTab: $0) } ?? idleChangeManager)
            }
    }

    // Asked on every switch: a manager with nothing staged takes the tab's current result without losing its redo.
    func describeCurrentResult(ofTab tabId: UUID) {
        guard let manager = existingChangeManager(forTab: tabId), !manager.hasChanges,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        describe(tab, in: manager)
    }

    private func describe(_ tab: QueryTab, in manager: DataChangeManager) {
        let rows = tabSessionRegistry.tableRows(for: tab.id)
        manager.describeTable(
            tableName: tab.tableContext.tableName ?? "",
            schemaName: tab.tableContext.schemaName,
            columns: rows.columns,
            primaryKeyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: connection.type,
            generatedColumns: rows.generatedColumns,
            rowMatchPolicy: rows.rowMatchPolicy,
            columnTypeNames: rows.columnTypeNames
        )
    }

    private func edits(forTab tabId: UUID) -> TabEdits {
        if let existing = tabEdits[tabId] { return existing }
        let manager = DataChangeManager()
        let undoManager = UndoManager()
        manager.undoManagerProvider = { undoManager }
        manager.onUndoApplied = { [weak self] result in self?.handleUndoResult(result, forTab: tabId) }
        manager.databaseType = connection.type
        manager.pluginDriver = rowWriter
        if let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
            describe(tab, in: manager)
        }
        let observers = [
            manager.$reloadVersion
                .removeDuplicates()
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.existingGridModel(forTab: tabId)?.repaintAllRows() },
            // Heard a turn later: the manager publishes before it stores, and by then a save has started the load.
            manager.$hasChanges
                .removeDuplicates()
                .dropFirst()
                .filter { !$0 }
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, tabManager.selectedTabId == tabId else { return }
                    resumeDeferredTableRefresh()
                },
        ]
        let edits = TabEdits(
            changes: manager,
            gridState: AnyChangeManager(manager),
            undoManager: undoManager,
            observers: observers
        )
        tabEdits[tabId] = edits
        return edits
    }
}
