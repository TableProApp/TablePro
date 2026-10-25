//
//  TableStructureView+ColumnReorder.swift
//  TablePro
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit
import TableProSQLGrammar

extension TableStructureView {
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
                        prepared, tableName: tableName, databaseType: connection.type, isConfirmationPreCleared: false
                    )
                    await finishColumnReorder(prepared, clearTarget: clearTarget)
                case .tableRebuild:
                    presentColumnReorderReview(prepared, clearTarget: clearTarget)
                @unknown default:
                    // A cost this build does not recognise is shown before it runs, never after.
                    presentColumnReorderReview(prepared, clearTarget: clearTarget)
                }
            } catch {
                reportColumnReorderFailure(error)
            }
        }
    }

    private func presentColumnReorderReview(
        _ prepared: StructureColumnReorderHandler.PreparedReorder,
        clearTarget: ColumnLayoutClearTarget?
    ) {
        guard let coordinator else { return }
        coordinator.tableRebuildRequest = TableRebuildReviewRequest(
            tableName: tableName,
            scope: prepared.scope,
            plan: prepared.plan,
            action: TableRebuildReviewRequest.Action(
                title: String(localized: "Rebuild Table"),
                operationDescription: StructureColumnReorderHandler.operationDescription
            ) {
                do {
                    try await StructureColumnReorderHandler.execute(
                        prepared, tableName: tableName, databaseType: connection.type, isConfirmationPreCleared: true
                    )
                    await finishColumnReorder(prepared, clearTarget: clearTarget)
                } catch {
                    if StructureApplyFailure(error).reportsFailure {
                        CatalogChangeService.post(
                            .changed(
                                CatalogChange(
                                    connectionId: prepared.scope.connectionId,
                                    database: prepared.scope.database,
                                    kinds: .tables
                                )
                            )
                        )
                    }
                    reportColumnReorderFailure(error)
                }
            }
        )
        coordinator.activeSheet = .tableRebuildReview
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
        adoptFetchedBaseline()
        isReloadingAfterSave = false
        if let clearTarget {
            coordinator?.clearColumnLayout(clearTarget)
        }
        DatabaseManager.shared.reportTableDefinitionChange(table: tableName, in: prepared.scope)
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: connection.id, database: prepared.scope.database, kinds: .tables))
        )
    }

    private func reportColumnReorderFailure(_ error: any Error) {
        guard let message = StructureApplyFailure(error).message else { return }
        AlertHelper.showErrorSheet(
            title: String(localized: "Column Reorder Failed"),
            message: message,
            window: coordinator?.contentWindow
        )
    }
}
