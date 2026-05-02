//
//  TabSession.swift
//  TablePro
//
//  Foundation type for the tab/window subsystem rewrite.
//  See docs/architecture/tab-subsystem-rewrite.md for the full design.
//

import Foundation
import Observation

/// Per-tab state container for the editor tab/window subsystem.
///
/// In the new architecture, one `TabSession` instance owns all per-tab state
/// (filters, hidden columns, row data, sort, pagination, etc.). The
/// `MainContentCoordinator` exposes per-tab mutation helpers; the legacy
/// shared per-window managers (filters, columns, table rows) are gone.
/// SwiftUI tracks mutations natively via the Observation framework, so views
/// don't need explicit subscriptions or stored callbacks.
///
/// PR1 (this PR) introduces the type as a parallel structure that mirrors
/// `QueryTab`'s state shape. Consumers still use `QueryTab` and the legacy
/// stores; subsequent PRs migrate field ownership into `TabSession` and
/// retire the old stores via the strangler-fig pattern.
///
/// This is a class (not a struct) because `@Observable` requires a reference
/// type. The mutation-by-array-index pattern that QueryTab uses
/// (`tabManager.tabs[index].field = value`) becomes direct property assignment
/// on a shared instance, which is what SwiftUI's Observation framework expects.
@Observable @MainActor
final class TabSession: Identifiable {
    // MARK: - Identity

    let id: UUID

    // MARK: - Tab metadata

    var title: String
    var tabType: TabType
    var isPreview: Bool

    // MARK: - Content

    var content: TabQueryContent

    // MARK: - Execution

    var execution: TabExecutionState

    // MARK: - Table context

    var tableContext: TabTableContext

    // MARK: - Display

    var display: TabDisplayState

    // MARK: - Per-tab UI state

    var pendingChanges: TabChangeSnapshot
    var selectedRowIndices: Set<Int>
    var sortState: SortState
    var filterState: TabFilterState
    var columnLayout: ColumnLayoutState
    var pagination: PaginationState

    // MARK: - Tracking

    var hasUserInteraction: Bool
    var schemaVersion: Int
    var metadataVersion: Int
    var paginationVersion: Int
    var loadEpoch: Int

    // MARK: - Session-only state

    var tableRows: TableRows
    var isEvicted: Bool

    // MARK: - Init

    /// Lift a `QueryTab` value into a `TabSession` reference. Used at the
    /// boundary between legacy code paths (which still pass `QueryTab` by
    /// value) and the new architecture (which holds `TabSession` references).
    init(queryTab: QueryTab) {
        self.id = queryTab.id
        self.title = queryTab.title
        self.tabType = queryTab.tabType
        self.isPreview = queryTab.isPreview
        self.content = queryTab.content
        self.execution = queryTab.execution
        self.tableContext = queryTab.tableContext
        self.display = queryTab.display
        self.pendingChanges = queryTab.pendingChanges
        self.selectedRowIndices = queryTab.selectedRowIndices
        self.sortState = queryTab.sortState
        self.filterState = queryTab.filterState
        self.columnLayout = queryTab.columnLayout
        self.pagination = queryTab.pagination
        self.hasUserInteraction = queryTab.hasUserInteraction
        self.schemaVersion = queryTab.schemaVersion
        self.metadataVersion = queryTab.metadataVersion
        self.paginationVersion = queryTab.paginationVersion
        self.loadEpoch = queryTab.loadEpoch
        self.tableRows = TableRows()
        self.isEvicted = false
    }

    /// Build a `TabSession` from primitive parameters, mirroring `QueryTab.init`.
    /// Used by callers that construct sessions directly without an intermediate
    /// `QueryTab` value.
    init(
        id: UUID = UUID(),
        title: String = "Query",
        query: String = "",
        tabType: TabType = .query,
        tableName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.tabType = tabType
        self.isPreview = false
        self.content = TabQueryContent(query: query)
        self.execution = TabExecutionState()
        self.tableContext = TabTableContext(tableName: tableName, isEditable: tabType == .table)
        self.display = TabDisplayState()
        self.pendingChanges = TabChangeSnapshot()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.pagination = PaginationState()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
        self.loadEpoch = 0
        self.tableRows = TableRows()
        self.isEvicted = false
    }

    // MARK: - Conversion

    /// Snapshot the current session state back into a `QueryTab` value. Used
    /// by code paths that haven't migrated yet (persistence, legacy stores).
    /// Pure read; callers can mutate the returned struct without affecting
    /// the session.
    func snapshot() -> QueryTab {
        var tab = QueryTab(
            id: id,
            title: title,
            query: content.query,
            tabType: tabType,
            tableName: tableContext.tableName
        )
        tab.isPreview = isPreview
        tab.content = content
        tab.execution = execution
        tab.tableContext = tableContext
        tab.display = display
        tab.pendingChanges = pendingChanges
        tab.selectedRowIndices = selectedRowIndices
        tab.sortState = sortState
        tab.filterState = filterState
        tab.columnLayout = columnLayout
        tab.pagination = pagination
        tab.hasUserInteraction = hasUserInteraction
        tab.schemaVersion = schemaVersion
        tab.metadataVersion = metadataVersion
        tab.paginationVersion = paginationVersion
        tab.loadEpoch = loadEpoch
        return tab
    }

    /// Replace the session's state from a `QueryTab` value, preserving the
    /// session's identity (`id`). Used when a tab's persisted state is
    /// reloaded from disk and the existing session must absorb the new state
    /// without observers losing track of the instance.
    func absorb(_ queryTab: QueryTab) {
        precondition(queryTab.id == id, "TabSession.absorb requires matching ids")
        self.title = queryTab.title
        self.tabType = queryTab.tabType
        self.isPreview = queryTab.isPreview
        self.content = queryTab.content
        self.execution = queryTab.execution
        self.tableContext = queryTab.tableContext
        self.display = queryTab.display
        self.pendingChanges = queryTab.pendingChanges
        self.selectedRowIndices = queryTab.selectedRowIndices
        self.sortState = queryTab.sortState
        self.filterState = queryTab.filterState
        self.columnLayout = queryTab.columnLayout
        self.pagination = queryTab.pagination
        self.hasUserInteraction = queryTab.hasUserInteraction
        self.schemaVersion = queryTab.schemaVersion
        self.metadataVersion = queryTab.metadataVersion
        self.paginationVersion = queryTab.paginationVersion
        self.loadEpoch = queryTab.loadEpoch
    }
}
