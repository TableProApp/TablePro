//
//  StructureGridStateStore.swift
//  TablePro
//

import Foundation

// The Structure grid's view state lives on the tab's session, one column layout per sub-tab, and never
// reaches a table's saved layout.
@MainActor
final class StructureGridStateStore: DataGridStateStore {
    weak var session: StructureEditingSession?
    private(set) var subTab: StructureTab = .columns

    var valueFilter = GridValueFilterState()
    var displayFormats: [ValueDisplayFormat?] = []
    var selectionSnapshot = GridSelectionSnapshot.empty
    var viewportAnchor: GridViewportPlacement?
    let layoutScope: DataGridLayoutScope = .ephemeral

    private var detachedLayouts: [StructureTab: ColumnLayoutState] = [:]
    private var detachedSort = SortState()

    var sortState: SortState {
        get { session?.sortState ?? detachedSort }
        set {
            guard let session else {
                detachedSort = newValue
                return
            }
            guard session.sortState != newValue else { return }
            session.sortState = newValue
        }
    }

    var columnLayout: ColumnLayoutState {
        get { session?.columnLayouts[subTab] ?? detachedLayouts[subTab] ?? ColumnLayoutState() }
        set {
            guard let session else {
                detachedLayouts[subTab] = newValue
                return
            }
            guard session.columnLayouts[subTab] != newValue else { return }
            session.columnLayouts[subTab] = newValue
        }
    }

    // Search, sort, filter and selection start over on another sub-tab; the column layout is kept per sub-tab.
    func switchSubTab(to tab: StructureTab) {
        guard tab != subTab else { return }
        subTab = tab
        valueFilter = GridValueFilterState()
        displayFormats = []
        selectionSnapshot = .empty
        viewportAnchor = nil
    }
}
