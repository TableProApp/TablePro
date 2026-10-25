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

    // The JSON inspector's route: a node tree can't hold ForeignKeyInfo, whose == compares a fresh UUID.
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

    // Never retargets the selected tab: the old guard ignored filters, sort and pins, so a cell arrow lost the reader's rows.
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

        // Resolved scope, not the raw catalog value: schema-less engines put the database there, giving the table a second identity.
        let target = ForeignKeyTargetScope.resolve(
            origin: sourceScope,
            referencedDatabase: fkInfo.referencedDatabase,
            referencedSchema: fkInfo.referencedSchema,
            databaseType: connection.type
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
                // The discard alert clears only staged cell edits, so a staged structure edit rules out re-querying (Back/Forward too).
                selectedTabAcceptsRefilter: selectedTab.map { !hasStagedStructureEdits(in: $0) } ?? false,
                anotherTabShowsReference: existing != nil
            )
        )

        // Jumps that leave the tab promote it, so the next sidebar click can't retarget it; re-filtering stays on the tab.
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
        // Built only when no open tab could take the jump; reusing one would write the FK filter over the user's own filters.
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

    // Asks what the rows were fetched with, not appliedFilters, which reads the unapplied draft and claimed a false match.
    private func showsOnlyFKPredicate(_ tab: QueryTab, filter: TableFilter) -> Bool {
        let applied = tab.filterState.executedFilters
        guard applied.count == 1 else { return false }
        return isSameFKPredicate(applied[0], filter)
    }

    // Matching the filter too keeps a click on a different row from re-filtering a tab opened for another one.
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

        // Hosted coordinators, not allActiveCoordinators(), which can hold one whose window is gone.
        for sibling in hostedTabRouting.coordinators(connectionId) where sibling !== self {
            guard let match = sibling.tabManager.tabs.first(where: matches) else { continue }
            return (sibling, match.id)
        }
        return nil
    }

    // One discard guard: applyFilters deferred behind the alert but setFKFilter didn't, so a refusal left a stale filter.
    private func refilterSelectedTab(with filter: TableFilter, showsReferenceAlready: Bool) {
        // Not recorded when the tab already shows this reference, or Back would step through identical entries.
        let departing = showsReferenceAlready ? nil : captureNavigationEntry()
        confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            filterCoordinator.commitReferenceFilter(filter)
            commitNavigationEntry(departing)
        }
    }
}
