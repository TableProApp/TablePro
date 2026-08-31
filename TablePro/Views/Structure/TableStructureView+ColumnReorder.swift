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
            isTable: !isViewObject,
            canEditSchema: connection.type.supportsSchemaEditing,
            hasStagedChanges: structureChangeManager.hasChanges,
            isRearranged: !searchText.isEmpty || structureSortDescriptor != nil
        )
    }

    func beginColumnReorder(fromIndex: Int, toIndex: Int) {
        let columnsSnapshot = structureChangeManager.workingColumns
        let clearTarget = coordinator?.selectedColumnLayoutClearTarget()
        let reorderScope = scope

        Task { @MainActor in
            do {
                let desiredOrder = try StructureColumnReorderHandler.desiredOrder(
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    columnNames: columnsSnapshot.map(\.name)
                )
                let prepared = try await StructureColumnReorderHandler.prepare(
                    desiredOrder: desiredOrder,
                    workingColumns: columnsSnapshot,
                    tableName: tableName,
                    scope: reorderScope
                )

                switch prepared.plan.cost {
                case .metadataOnly:
                    try await StructureColumnReorderHandler.execute(
                        prepared, tableName: tableName, databaseType: connection.type
                    )
                    await finishColumnReorder(prepared, clearTarget: clearTarget)
                case .tableRebuild:
                    presentColumnReorderReview(prepared, clearTarget: clearTarget)
                @unknown default:
                    /// A cost this build does not recognise is shown before it runs, never after.
                    presentColumnReorderReview(prepared, clearTarget: clearTarget)
                }
            } catch {
                reportColumnReorderFailure(error)
            }
        }
    }

    /// A rebuild is never run on the drop. It is shown in full, with what it cannot carry over, and
    /// the user either runs it here or takes the script to a query tab.
    private func presentColumnReorderReview(
        _ prepared: StructureColumnReorderHandler.PreparedReorder,
        clearTarget: ColumnLayoutClearTarget?
    ) {
        guard let coordinator else { return }
        coordinator.columnReorderRequest = ColumnReorderReviewRequest(
            tableName: tableName,
            scope: prepared.scope,
            plan: prepared.plan,
            perform: {
                do {
                    try await StructureColumnReorderHandler.execute(
                        prepared, tableName: tableName, databaseType: connection.type
                    )
                    await finishColumnReorder(prepared, clearTarget: clearTarget)
                } catch {
                    reportColumnReorderFailure(error)
                }
            }
        )
        coordinator.activeSheet = .columnReorderReview
    }

    private func finishColumnReorder(
        _ prepared: StructureColumnReorderHandler.PreparedReorder,
        clearTarget: ColumnLayoutClearTarget?
    ) async {
        await services.queryHistoryManager.record(
            QueryHistoryRecordRequest(
                query: prepared.plan.scriptStatements
                    .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                    .joined(separator: "\n"),
                connectionId: prepared.scope.connectionId,
                databaseName: prepared.scope.database,
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
