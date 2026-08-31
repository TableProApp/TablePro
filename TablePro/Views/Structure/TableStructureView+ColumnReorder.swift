//
//  TableStructureView+ColumnReorder.swift
//  TablePro
//
//  Dragging a column row to a new position, and what happens when the engine cannot.
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit

extension TableStructureView {
    /// Whether a column may be dragged right now, and the reason shown on the row number when not.
    ///
    /// Read by both the grid, which decides whether to offer the drag at all, and the delegate,
    /// which decides whether there is a handler behind it. One answer, so the two cannot disagree.
    var columnReorderAvailability: ColumnReorderAvailability {
        ColumnReorderPolicy.resolve(
            support: PluginManager.shared.columnReorderSupport(for: connection.type),
            engineName: connection.type.displayName,
            isColumnsTab: selectedTab == .columns,
            canEditSchema: connection.type.supportsSchemaEditing,
            hasStagedChanges: structureChangeManager.hasChanges,
            isRearranged: !searchText.isEmpty || structureSortDescriptor != nil
        )
    }

    func beginColumnReorder(fromIndex: Int, toIndex: Int) {
        let columnsSnapshot = structureChangeManager.workingColumns
        let clearTarget = coordinator?.selectedColumnLayoutClearTarget()

        Task { @MainActor in
            do {
                let desiredOrder = try StructureColumnReorderHandler.desiredOrder(
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    columnNames: columnsSnapshot.map(\.name)
                )
                let plan = try await StructureColumnReorderHandler.plan(
                    desiredOrder: desiredOrder,
                    workingColumns: columnsSnapshot,
                    tableName: tableName,
                    schema: schemaName,
                    connectionId: connection.id
                )

                switch plan.cost {
                case .metadataOnly:
                    try await StructureColumnReorderHandler.execute(plan, connectionId: connection.id)
                    await finishColumnReorder(plan: plan, clearTarget: clearTarget)
                case .tableRebuild:
                    presentColumnReorderReview(plan: plan, clearTarget: clearTarget)
                @unknown default:
                    /// A cost this build does not recognise is shown before it runs, never after.
                    presentColumnReorderReview(plan: plan, clearTarget: clearTarget)
                }
            } catch {
                reportColumnReorderFailure(error)
            }
        }
    }

    /// A rebuild is never run on the drop. It is shown in full, with what it cannot carry over, and
    /// the user either runs it here or takes the script to a query tab.
    private func presentColumnReorderReview(plan: PluginColumnReorderPlan, clearTarget: ColumnLayoutClearTarget?) {
        guard let coordinator else { return }
        coordinator.columnReorderRequest = ColumnReorderReviewRequest(
            tableName: tableName,
            plan: plan,
            perform: {
                do {
                    try await StructureColumnReorderHandler.execute(plan, connectionId: connection.id)
                    await finishColumnReorder(plan: plan, clearTarget: clearTarget)
                } catch {
                    reportColumnReorderFailure(error)
                }
            }
        )
        coordinator.activeSheet = .columnReorderReview
    }

    private func finishColumnReorder(plan: PluginColumnReorderPlan, clearTarget: ColumnLayoutClearTarget?) async {
        await services.queryHistoryManager.record(
            QueryHistoryRecordRequest(
                query: plan.statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n"),
                connectionId: connection.id,
                databaseName: DatabaseManager.shared.browseDatabaseName(for: connection),
                databaseType: connection.type,
                source: .structureDDL,
                executionTime: 0,
                rowCount: -1,
                wasSuccessful: true
            )
        )
        isReloadingAfterSave = true
        await loadColumns()
        loadSchemaForEditing()
        isReloadingAfterSave = false
        if let clearTarget {
            coordinator?.clearColumnLayout(clearTarget)
        }
        AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: connection.id))
    }

    private func reportColumnReorderFailure(_ error: any Error) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Column Reorder Failed"),
            message: error.localizedDescription,
            window: coordinator?.contentWindow
        )
    }
}
