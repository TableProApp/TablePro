//
//  QueryTabGridStateStore.swift
//  TablePro
//

import Foundation

@MainActor
final class QueryTabGridStateStore: DataGridStateStore {
    private static let layoutPersistDelay: Duration = .milliseconds(500)

    let tabId: UUID
    private weak var coordinator: MainContentCoordinator?
    private let persister: FileColumnLayoutPersister

    // Kept here rather than on the tab on every click: a tab write re-renders every view of the window.
    var selectionSnapshot: GridSelectionSnapshot

    private var ephemeralFormats: (key: EphemeralFormatKey, formats: [ValueDisplayFormat?])?
    private var pendingLayout: (layout: ColumnLayoutState, key: ColumnLayoutTableKey)?
    private var layoutPersistTask: Task<Void, Never>?

    init(
        tabId: UUID,
        coordinator: MainContentCoordinator,
        persister: FileColumnLayoutPersister = .shared
    ) {
        self.tabId = tabId
        self.coordinator = coordinator
        self.persister = persister
        self.selectionSnapshot = coordinator.tabManager.tabs.first { $0.id == tabId }?.selectionSnapshot ?? .empty
    }

    private var tab: QueryTab? {
        coordinator?.tabManager.tabs.first { $0.id == tabId }
    }

    private var tableRows: TableRows {
        coordinator?.tabSessionRegistry.existingTableRows(for: tabId) ?? TableRows()
    }

    var layoutScope: DataGridLayoutScope {
        guard let tab, tab.tabType == .table, let key = coordinator?.columnLayoutTableKey(for: tab) else {
            return .ephemeral
        }
        return .table(key)
    }

    // MARK: - Sort and value filter

    // The tab takes the sort only once the reload it asks for is confirmed, so the write is a request.
    var sortState: SortState {
        get { tab?.sortState ?? SortState() }
        set { coordinator?.requestSort(newValue, forTab: tabId) }
    }

    var valueFilter: GridValueFilterState {
        get { tab?.valueFilter ?? GridValueFilterState() }
        set {
            guard let coordinator, tab?.valueFilter != newValue else { return }
            coordinator.setValueFilter(newValue, forTab: tabId)
            coordinator.gridDisplayRevision &+= 1
        }
    }

    // MARK: - Column layout

    var columnLayout: ColumnLayoutState {
        get {
            guard let tab else { return ColumnLayoutState() }
            var layout = tab.columnLayout
            switch layoutScope {
            case .table(let key):
                if let stored = pendingLayout?.layout ?? persister.load(for: key) {
                    layout.columnWidths = stored.columnWidths
                    layout.columnContentWidths = stored.columnContentWidths
                    layout.columnOrder = stored.columnOrder
                    layout.frozenColumnCount = stored.frozenColumnCount
                }
            case .ephemeral:
                if let order = layout.columnOrder, !Self.canRestoreColumnOrder(order, columns: tableRows.columns) {
                    layout.columnOrder = nil
                }
            }
            return layout
        }
        set {
            guard let coordinator, let current = tab?.columnLayout else { return }
            var layout = newValue
            // The getter hid an order saved for other columns; it stays for when those columns come back.
            if case .ephemeral = layoutScope, layout.columnOrder == nil, let kept = current.columnOrder,
               !Self.canRestoreColumnOrder(kept, columns: tableRows.columns) {
                layout.columnOrder = kept
            }
            if current != layout {
                coordinator.isUpdatingColumnLayout = true
                coordinator.tabManager.mutate(tabId: tabId) { $0.columnLayout = layout }
                Task { @MainActor [weak coordinator] in
                    coordinator?.isUpdatingColumnLayout = false
                }
            }
            guard case .table(let key) = layoutScope else { return }
            if newValue.hasNoGeometry {
                discardPendingLayout()
                persister.clearGeometry(for: key)
                return
            }
            schedulePersist(newValue, key: key)
        }
    }

    // A saved order names columns, which identify one only while the names are unique and match the result's (#1565).
    private static func canRestoreColumnOrder(_ order: [String], columns: [String]) -> Bool {
        let names = Set(columns)
        return names.count == columns.count && Set(order) == names
    }

    private func schedulePersist(_ layout: ColumnLayoutState, key: ColumnLayoutTableKey) {
        layoutPersistTask?.cancel()
        pendingLayout = (layout, key)
        layoutPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.layoutPersistDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingLayout()
        }
    }

    func flushPendingLayout() {
        layoutPersistTask?.cancel()
        layoutPersistTask = nil
        guard let pending = pendingLayout else { return }
        pendingLayout = nil
        persister.save(pending.layout, for: pending.key)
    }

    // For a table that is gone: a flush would write the layout back over the clear.
    func discardPendingLayout() {
        layoutPersistTask?.cancel()
        layoutPersistTask = nil
        pendingLayout = nil
    }

    // MARK: - Display formats

    var displayFormats: [ValueDisplayFormat?] {
        get {
            guard let coordinator, let tab else { return [] }
            if let ephemeralFormats, ephemeralFormats.key == EphemeralFormatKey(tab: tab, columns: tableRows.columns) {
                return ephemeralFormats.formats
            }
            return coordinator.displayFormats(for: tab)
        }
        set {
            guard let coordinator, let tab else { return }
            let columns = tableRows.columns
            guard case .table = layoutScope, let scope = tab.tableContext.scope(connectionId: coordinator.connectionId) else {
                ephemeralFormats = (EphemeralFormatKey(tab: tab, columns: columns), newValue)
                coordinator.gridDisplayRevision &+= 1
                return
            }
            let current = coordinator.displayFormats(for: tab)
            let storageKeys = ValueDisplayFormatColumnKey.storageKeys(for: columns)
            for (index, storageKey) in storageKeys.enumerated() {
                let format = index < newValue.count ? newValue[index] : nil
                let previous = index < current.count ? current[index] : nil
                guard format != previous else { continue }
                ValueDisplayFormatService.shared.setOverride(format, columnKey: storageKey, scope: scope)
            }
            coordinator.gridDisplayRevision &+= 1
        }
    }

    // MARK: - Viewport

    var viewportAnchor: GridViewportPlacement? {
        get {
            guard let session = coordinator?.tabSessionRegistry.session(for: tabId),
                  let stage = session.viewportStage,
                  stage.bufferEpoch == session.bufferEpoch else { return nil }
            return stage.placement
        }
        set {
            guard let registry = coordinator?.tabSessionRegistry else { return }
            guard let newValue else {
                _ = registry.takeViewportPlacement(for: tabId)
                return
            }
            registry.stageViewportPlacement(newValue, for: tabId)
        }
    }
}

private struct EphemeralFormatKey: Equatable {
    let resultSetId: UUID?
    let schemaVersion: Int
    let columns: [String]

    init(tab: QueryTab, columns: [String]) {
        resultSetId = tab.display.activeResultSetId
        schemaVersion = tab.schemaVersion
        self.columns = columns
    }
}

private extension ColumnLayoutState {
    var hasNoGeometry: Bool {
        columnWidths.isEmpty
            && columnContentWidths?.isEmpty != false
            && columnOrder == nil
            && frozenColumnCount == 0
    }
}
