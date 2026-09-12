//
//  MainContentCoordinator+FKNavigation.swift
//  TablePro
//
//  Foreign key navigation operations for MainContentCoordinator
//

import AppKit
import Foundation
import os

private let fkNavigationLogger = Logger(subsystem: "com.TablePro", category: "FKNavigation")

extension MainContentCoordinator {
    // MARK: - Foreign Key Navigation

    /// The JSON inspector's own route to the same navigation. It holds a `JSONForeignKeyRef`,
    /// which is a `ForeignKeyInfo` without the identity and the referential actions, because a node
    /// tree cannot hold a type whose `==` is a fresh `UUID`.
    func navigateToFKReference(reference: JSONForeignKeyRef, value: String) {
        navigateToFKReference(
            value: value,
            fkInfo: ForeignKeyInfo(
                name: "",
                column: reference.column,
                referencedTable: reference.referencedTable,
                referencedColumn: reference.referencedColumn,
                referencedSchema: reference.referencedSchema
            ),
            intent: .follow
        )
    }

    /// Navigate to the referenced table filtered by the FK value.
    ///
    /// The choice is `ReferenceNavigationPlanner`'s, so it can be read and tested in one place. It
    /// never re-points the selected tab at a different table. A tab already on the referenced table
    /// is re-filtered, which is a move within the table the reader is in and which Back undoes.
    /// Retargeting used to be guarded by a predicate of its own, which knew about unsaved edits but
    /// not about applied filters, a sort or pinned results, so the arrow in a cell took over a tab
    /// the sidebar would have left alone and the reader lost the rows they were reading.
    func navigateToFKReference(value: String, fkInfo: ForeignKeyInfo, intent: ReferenceOpenIntent) {
        let referencedTable = fkInfo.referencedTable
        let referencedColumn = fkInfo.referencedColumn

        fkNavigationLogger.debug("FK navigate: \(referencedTable).\(referencedColumn) = \(value) intent=\(String(describing: intent))")

        let filter = TableFilter(
            columnName: referencedColumn,
            filterOperator: .equal,
            value: value
        )

        guard let sourceScope = selectedTabScope else {
            fkNavigationLogger.error("FK navigate skipped: the source tab is not bound to a database")
            return
        }

        /// The referenced table's own database and schema, not the raw catalog value. An engine
        /// with no schema layer names the referenced database in the slot its catalog calls a
        /// schema, and carrying that through gave a table reached by a key a different identity
        /// from the same table opened from the sidebar: its own filters, its own column layout, no
        /// tab to reuse, and a rename that never found it.
        let target = ForeignKeyTargetScope.resolve(
            origin: sourceScope, referencedSchema: fkInfo.referencedSchema, databaseType: connection.type
        )
        let targetDatabase = target.database
        let targetSchema = target.schema

        let selectedTab = tabManager.selectedTab
        let showsTarget = selectedTab.map {
            matchesFKTarget($0, table: referencedTable, database: targetDatabase, schema: targetSchema)
        } ?? false
        let existing = intent == .follow ? openFKTargetTab(
            table: referencedTable,
            database: targetDatabase,
            schema: targetSchema,
            filter: filter
        ) : nil

        let plan = ReferenceNavigationPlanner.plan(
            for: ReferenceNavigationContext(
                intent: intent,
                selectedTabShowsTarget: showsTarget,
                /// The discard alert clears staged cell edits and nothing else, so re-querying
                /// under a staged structure edit would promise something this path cannot keep.
                /// Back and Forward stand down on the same tab for the same reason.
                selectedTabAcceptsRefilter: selectedTab.map { !hasStagedStructureEdits(in: $0) } ?? false,
                anotherTabShowsReference: existing != nil
            )
        )

        /// Both jumps that leave the tab keep it. The reader navigated away from it rather than
        /// clicking past it, so the next sidebar click must not retarget it; `openTableTab` promotes
        /// before it hands off for the same reason. Re-filtering stays on the tab, so it does not.
        switch plan {
        case .refilterSelectedTab:
            refilterSelectedTab(with: filter, showsReferenceAlready: selectedTab.map {
                showsOnlyFKPredicate($0, filter: filter)
            } ?? false)
        case .revealExistingTab:
            promotePreviewTab()
            guard let existing, hostedTabRouting.reveal(existing.coordinator, existing.tabId) else {
                openReferenceInNewTab(
                    filter: filter,
                    referencedTable: referencedTable,
                    databaseName: targetDatabase,
                    schemaName: targetSchema
                )
                return
            }
        case .openNewTab:
            promotePreviewTab()
            openReferenceInNewTab(
                filter: filter,
                referencedTable: referencedTable,
                databaseName: targetDatabase,
                schemaName: targetSchema
            )
        }
    }

    private func openReferenceInNewTab(
        filter: TableFilter,
        referencedTable: String,
        databaseName: String,
        schemaName: String?
    ) {
        openTabInNewWindow(
            makeFKReferencePayload(
                filter: filter,
                referencedTable: referencedTable,
                databaseName: databaseName,
                schemaName: schemaName
            )
        )
    }

    func makeFKReferencePayload(
        filter: TableFilter,
        referencedTable: String,
        databaseName: String?,
        schemaName: String?
    ) -> EditorTabPayload {
        let fkFilterState = TabFilterState(
            filters: [filter],
            commit: .all,
            isVisible: true,
            filterLogicMode: .and
        )
        /// This payload is only built once no open tab could take the jump, so it must land in a
        /// tab of its own. Reusing one would write the FK filter over filters the user applied
        /// there, and leave the grid on rows the new filter never ran against.
        return EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: referencedTable,
            databaseName: databaseName,
            schemaName: schemaName,
            isView: false,
            forcesNewTab: true,
            initialFilterState: fkFilterState
        )
    }

    /// Toggle FK preview for the currently focused cell in the data grid.
    /// Called from the menu command system (Settings > Keyboard rebindable).
    /// `focusedColumn` is a position in `tableView.tableColumns`, which carries the row-number
    /// column and a hidden spacer before the data, and which the reader can reorder. Subtracting a
    /// fixed offset from it named a different column than the one they were on, or none at all, so
    /// this resolves it by column identity the way the key-equivalent path already does.
    func toggleFKPreviewForFocusedCell() {
        guard let tableView = NSApp.keyWindow?.firstResponder as? KeyHandlingTableView,
              let coordinator = tableView.coordinator,
              tableView.selectedRow >= 0,
              tableView.presentsDataColumn(at: tableView.focusedColumn),
              let columnIndex = DataGridView.dataColumnIndex(
                  for: tableView.focusedColumn,
                  in: tableView,
                  schema: coordinator.identitySchema
              )
        else { return }
        coordinator.toggleForeignKeyPreview(
            tableView: tableView,
            row: tableView.selectedRow,
            column: tableView.focusedColumn,
            columnIndex: columnIndex
        )
    }

    private func matchesFKTarget(_ tab: QueryTab, table: String, database: String, schema: String?) -> Bool {
        tab.tabType == .table
            && tab.tableContext.tableName == table
            && tab.tableContext.databaseName == database
            && tab.tableContext.schemaName == schema
    }

    private func isSameFKPredicate(_ lhs: TableFilter, _ rhs: TableFilter) -> Bool {
        lhs.columnName == rhs.columnName
            && lhs.filterOperator == rhs.filterOperator
            && lhs.value == rhs.value
    }

    /// Whether this tab is already showing exactly this reference and nothing else. One definition,
    /// because the reuse search and the history both have to agree on what "already here" means.
    ///
    /// Asked of what the rows were fetched with, never of `appliedFilters`, which resolves from the
    /// panel's editable draft. Typing `id = 42` into a tab showing `id = 7` and not pressing Apply
    /// made that tab answer yes, and revealing it runs no query, so the reader landed on the rows
    /// for 7 while the app reported it had found the reference.
    private func showsOnlyFKPredicate(_ tab: QueryTab, filter: TableFilter) -> Bool {
        let applied = tab.filterState.executedFilters
        guard applied.count == 1 else { return false }
        return isSameFKPredicate(applied[0], filter)
    }

    /// A tab already showing exactly this reference. Matching the filter too keeps a click on a
    /// different row from re-filtering a tab the user opened for another one.
    private func openFKTargetTab(
        table: String,
        database: String,
        schema: String?,
        filter: TableFilter
    ) -> (coordinator: MainContentCoordinator, tabId: UUID)? {
        func matches(_ tab: QueryTab) -> Bool {
            matchesFKTarget(tab, table: table, database: database, schema: schema)
                && showsOnlyFKPredicate(tab, filter: filter)
        }

        if let match = tabManager.tabs.first(where: matches) {
            return (self, match.id)
        }

        /// Hosted coordinators, not `allActiveCoordinators()`, which is a registry of every
        /// coordinator SwiftUI has built and can hold one whose window is gone. A reveal has to
        /// land somewhere the reader can see.
        for sibling in hostedTabRouting.coordinators(connectionId) where sibling !== self {
            guard let match = sibling.tabManager.tabs.first(where: matches) else { continue }
            return (sibling, match.id)
        }
        return nil
    }

    /// Re-points the tab the reader is already on at another row of the same table.
    ///
    /// Everything happens inside one discard guard. The pair this replaced ran `applyFilters`,
    /// which defers behind the alert, beside `setFKFilter`, which does not, so refusing the alert
    /// left the panel showing an applied filter the grid was never re-queried for and pushed a
    /// history entry for a jump that never happened, dropping the forward stack with it.
    private func refilterSelectedTab(with filter: TableFilter, showsReferenceAlready: Bool) {
        /// Re-filtering the tab in place is a jump like any other, so it goes on the history.
        /// Clicking the reference the tab is already showing is not, and recording it would stack
        /// identical entries a reader has to press Back through.
        let departing = showsReferenceAlready ? nil : captureNavigationEntry()
        confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            filterCoordinator.commitReferenceFilter(filter)
            commitNavigationEntry(departing)
        }
    }
}
