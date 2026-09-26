//
//  StructureSavePlan.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum StructureSavePlan {
    case alter(SchemaChangeScript)
    case rebuild(StructureRebuildPlanRunner.Prepared)

    internal var displayStatements: [String] {
        switch self {
        case .alter(let script):
            script.statements.map(\.sql)
        case .rebuild(let prepared):
            prepared.plan.scriptStatements
        }
    }
}

internal extension StructureEditingSession {
    func stagedSavePlan(for changes: [SchemaChange]) async throws -> StructureSavePlan {
        let support = PluginManager.shared.foreignKeyEditSupport(for: connection.type)
        guard StructureTableRebuildHandler.requiresRebuild(changes: changes, support: support) else {
            return .alter(
                try await DatabaseManager.shared.schemaChangeStatements(
                    tableName: tableName,
                    changes: changes,
                    scope: scope
                )
            )
        }
        return .rebuild(
            try await StructureTableRebuildHandler.prepare(changes: changes, tableName: tableName, scope: scope)
        )
    }

    func previewStagedChanges(coordinator: MainContentCoordinator) async {
        let changes = changeManager.getChangesArray()
        guard !changes.isEmpty else { return }

        let plan: StructureSavePlan
        do {
            plan = try await stagedSavePlan(for: changes)
        } catch {
            guard mayPresentPreview(on: coordinator) else { return }
            coordinator.toolbarState.previewStatements = ["-- Error generating SQL: \(error.localizedDescription)"]
            coordinator.activeSheet = .sqlPreview
            return
        }

        guard mayPresentPreview(on: coordinator) else { return }
        switch plan {
        case .alter:
            coordinator.toolbarState.previewStatements = plan.displayStatements
            coordinator.activeSheet = .sqlPreview
        case .rebuild(let prepared):
            coordinator.tableRebuildRequest = TableRebuildReviewRequest(
                tableName: prepared.tableName,
                scope: prepared.scope,
                plan: prepared.plan,
                action: nil
            )
            coordinator.activeSheet = .tableRebuildReview
        }
    }

    private func mayPresentPreview(on coordinator: MainContentCoordinator) -> Bool {
        guard coordinator.activeSheet == nil,
              let selectedTab = coordinator.tabManager.selectedTab,
              selectedTab.display.resultsViewMode == .structure
        else {
            return false
        }
        return coordinator.structureSessions[selectedTab.id] === self
    }
}
