//
//  DatabaseTreeRowView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct DatabaseTreeRowActions {
    let coordinator: MainContentCoordinator?
    let isReadOnly: Bool
    let selectedTables: () -> Set<TableInfo>
    let activate: (DatabaseTreeTableRef) async -> Void
    let setActiveDatabase: (String) -> Void
    let setActiveSchema: (_ database: String, _ schema: String) -> Void
    let refreshDatabase: (String) -> Void
    let refreshObjects: (_ database: String, _ schema: String?) -> Void
    let showRoutineDDL: (RoutineInfo) -> Void
    let batchToggleTruncate: ([String]) -> Void
    let batchToggleDelete: ([String]) -> Void
}

struct DatabaseTreeRowContext {
    let activeDatabase: String?
    let activeSchema: String?
    let systemSchemas: Set<String>
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
}

struct DatabaseTreeRowView: View {
    let node: DatabaseTreeNode
    let isEmphasized: Bool
    let context: DatabaseTreeRowContext
    let actions: DatabaseTreeRowActions

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .database(let metadata):
            databaseRow(metadata)
        case .schema(let database, let schema):
            schemaRow(database: database, schema: schema)
        case .table(let ref):
            tableRow(ref)
        case .routine(let ref):
            routineRow(ref)
        case .status(let status):
            statusRow(status)
        }
    }

    // MARK: - Database

    private func databaseRow(_ metadata: DatabaseMetadata) -> some View {
        let name = metadata.name
        let isActive = name == context.activeDatabase
        return Label {
            Text(name)
                .fontWeight(isActive ? .bold : .regular)
        } icon: {
            Image(systemName: metadata.isSystemDatabase ? "gearshape" : "cylinder")
        }
        .lineLimit(1)
        .foregroundStyle(foreground(isActive: isActive, isSystem: metadata.isSystemDatabase))
        .contextMenu {
            Button(String(localized: "Use as Active Database")) {
                actions.setActiveDatabase(name)
            }
            .disabled(isActive)
            Button(String(localized: "Refresh")) {
                actions.refreshDatabase(name)
            }
        }
    }

    // MARK: - Schema

    private func schemaRow(database: String, schema: String) -> some View {
        let isActive = database == context.activeDatabase && schema == context.activeSchema
        return Label {
            Text(schema)
                .fontWeight(isActive ? .bold : .regular)
        } icon: {
            Image(systemName: "folder")
        }
        .lineLimit(1)
        .foregroundStyle(foreground(isActive: isActive, isSystem: context.systemSchemas.contains(schema)))
        .contextMenu {
            Button(String(localized: "Use as Active Schema")) {
                actions.setActiveSchema(database, schema)
            }
            .disabled(isActive)
            Button(String(localized: "Refresh")) {
                actions.refreshObjects(database, schema)
            }
        }
    }

    // MARK: - Table

    private func tableRow(_ ref: DatabaseTreeTableRef) -> some View {
        TableRow(
            table: ref.table,
            isPendingTruncate: context.pendingTruncates.contains(ref.table.name),
            isPendingDelete: context.pendingDeletes.contains(ref.table.name)
        )
        .contextMenu {
            SidebarContextMenu(
                clickedTable: ref.table,
                selectedTables: actions.selectedTables(),
                isReadOnly: actions.isReadOnly,
                onBatchToggleTruncate: actions.batchToggleTruncate,
                onBatchToggleDelete: actions.batchToggleDelete,
                coordinator: actions.coordinator,
                activateBeforeAction: { await actions.activate(ref) }
            )
        }
    }

    // MARK: - Routine

    private func routineRow(_ ref: DatabaseTreeRoutineRef) -> some View {
        RoutineRowView(routine: ref.routine)
            .contextMenu {
                RoutineContextMenu(routine: ref.routine, onShowDDL: actions.showRoutineDDL)
            }
    }

    // MARK: - Status

    @ViewBuilder
    private func statusRow(_ status: DatabaseTreeNode.Status) -> some View {
        switch status {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Loading\u{2026}"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .empty:
            Text(String(localized: "No items"))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func foreground(isActive: Bool, isSystem: Bool) -> AnyShapeStyle {
        if isEmphasized { return AnyShapeStyle(.white) }
        if isActive { return AnyShapeStyle(.tint) }
        if isSystem { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }
}
