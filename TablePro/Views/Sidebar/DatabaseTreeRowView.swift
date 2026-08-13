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
    let selectedContainers: () -> [DatabaseContainerRef]
    let activate: (DatabaseTreeTableRef) async -> Void
    let setActiveDatabase: (String) -> Void
    let setActiveSchema: (_ database: String, _ schema: String) -> Void
    let refreshContainers: ([DatabaseContainerRef]) -> Void
    let exportContainers: ([DatabaseContainerRef]) -> Void
    let dropContainers: ([DatabaseContainerRef]) -> Void
    let showRoutineDDL: (RoutineInfo) -> Void
    let batchToggleTruncate: ([String]) -> Void
    let batchToggleDelete: ([String]) -> Void
    let removeRecent: (DatabaseTreeTableRef) -> Void
    let clearRecents: () -> Void
}

struct DatabaseTreeRowContext {
    let databaseType: DatabaseType
    let activeDatabase: String?
    let activeSchema: String?
    let systemSchemas: Set<String>
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
    var isExternalSchema: @MainActor (String, String) -> Bool = { _, _ in false }
}

struct DatabaseTreeRowView: View {
    let node: DatabaseTreeNode
    let isEmphasized: Bool
    let context: DatabaseTreeRowContext
    let actions: DatabaseTreeRowActions

    private var containerEntityName: String {
        PluginManager.shared.containerEntityName(for: context.databaseType)
    }

    private var schemaEntityName: String {
        PluginManager.shared.schemaEntityName(for: context.databaseType)
    }

    var body: some View {
        if hasContextMenu {
            row.contextMenu {
                menuItems
                Divider()
                SidebarViewOptionsMenu()
            }
        } else {
            row
        }
    }

    private var row: some View {
        rowContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowContent: some View {
        switch node.kind {
        case .recentSection:
            header(
                text: String(localized: "Recent"),
                systemImage: "clock.arrow.circlepath",
                isActive: false,
                isSystem: false
            )
        case .recentTable(let ref):
            TableRow(
                table: ref.table,
                isPendingTruncate: context.pendingTruncates.contains(ref.table.name),
                isPendingDelete: context.pendingDeletes.contains(ref.table.name)
            )
            .foregroundStyle(isEmphasized ? AnyShapeStyle(Color.emphasizedSelectionLabel) : AnyShapeStyle(.primary))
        case .database(let metadata):
            header(
                text: metadata.name,
                systemImage: metadata.isSystemDatabase ? "gearshape" : "cylinder",
                isActive: metadata.name == context.activeDatabase,
                isSystem: metadata.isSystemDatabase
            )
        case .schema(let database, let schema):
            header(
                text: schema,
                systemImage: context.isExternalSchema(database, schema) ? "folder.badge.gearshape" : "folder",
                isActive: database == context.activeDatabase && schema == context.activeSchema,
                isSystem: context.systemSchemas.contains(schema),
                caption: context.isExternalSchema(database, schema) ? String(localized: "External") : nil
            )
        case .table(let ref):
            TableRow(
                table: ref.table,
                isPendingTruncate: context.pendingTruncates.contains(ref.table.name),
                isPendingDelete: context.pendingDeletes.contains(ref.table.name)
            )
            .foregroundStyle(isEmphasized ? AnyShapeStyle(Color.emphasizedSelectionLabel) : AnyShapeStyle(.primary))
        case .routine(let ref):
            RoutineRowView(routine: ref.routine)
                .foregroundStyle(isEmphasized ? AnyShapeStyle(Color.emphasizedSelectionLabel) : AnyShapeStyle(.primary))
        case .status(let status):
            statusRow(status)
        }
    }

    private func header(
        text: String,
        systemImage: String,
        isActive: Bool,
        isSystem: Bool,
        caption: String? = nil
    ) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(text)
                    .fontWeight(isActive ? .bold : .regular)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
        .lineLimit(1)
        .foregroundStyle(foreground(isActive: isActive, isSystem: isSystem))
    }

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

    private var hasContextMenu: Bool {
        switch node.kind {
        case .status, .recentSection: return false
        default: return true
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        switch node.kind {
        case .recentSection:
            EmptyView()
        case .recentTable(let ref):
            SidebarContextMenu(
                clickedTable: ref.table,
                selectedTables: [ref.table],
                isReadOnly: actions.isReadOnly,
                onBatchToggleTruncate: actions.batchToggleTruncate,
                onBatchToggleDelete: actions.batchToggleDelete,
                coordinator: actions.coordinator,
                activateBeforeAction: { await actions.activate(ref) }
            )
            Divider()
            Button(String(localized: "Remove from Recent")) {
                actions.removeRecent(ref)
            }
            Button(String(localized: "Clear Recent Tables")) {
                actions.clearRecents()
            }
        case .database(let metadata):
            containerMenuItems(for: .database(metadata.name, isSystem: metadata.isSystemDatabase))
        case .schema(let database, let schema):
            containerMenuItems(
                for: .schema(database: database, schema: schema, isSystem: context.systemSchemas.contains(schema))
            )
        case .table(let ref):
            SidebarContextMenu(
                clickedTable: ref.table,
                selectedTables: actions.selectedTables(),
                isReadOnly: actions.isReadOnly,
                onBatchToggleTruncate: actions.batchToggleTruncate,
                onBatchToggleDelete: actions.batchToggleDelete,
                coordinator: actions.coordinator,
                activateBeforeAction: { await actions.activate(ref) }
            )
        case .routine(let ref):
            RoutineContextMenu(routine: ref.routine, onShowDDL: actions.showRoutineDDL)
        case .status:
            EmptyView()
        }
    }

    @ViewBuilder
    private func containerMenuItems(for clicked: DatabaseContainerRef) -> some View {
        let targets = SidebarMenuTarget.resolveContainers(clicked: clicked, selection: actions.selectedContainers())
        let droppable = ContainerDropEligibility.droppable(targets, context: dropEligibilityContext)

        Button(useAsActiveTitle(for: clicked)) {
            useAsActive(clicked)
        }
        .disabled(targets.count > 1 || isActive(clicked))

        Button(String(localized: "Refresh")) {
            actions.refreshContainers(targets)
        }

        Button(copyNamesTitle(count: targets.count)) {
            ClipboardService.shared.writeText(targets.map(\.name).joined(separator: ","))
        }

        if ExportPreselection.canPreselect(containers: targets, activeDatabase: context.activeDatabase) {
            Button(String(localized: "Export…")) {
                actions.exportContainers(targets)
            }
        }

        if !droppable.isEmpty {
            Divider()

            Button(dropRequest(for: droppable).menuTitle, role: .destructive) {
                actions.dropContainers(droppable)
            }
        }
    }

    private func useAsActiveTitle(for container: DatabaseContainerRef) -> String {
        String(
            format: String(localized: "Use as Active %@"),
            container.kind == .schema ? schemaEntityName : containerEntityName
        )
    }

    private func useAsActive(_ container: DatabaseContainerRef) {
        switch container.kind {
        case .database:
            actions.setActiveDatabase(container.database)
        case .schema:
            guard let schema = container.schema else { return }
            actions.setActiveSchema(container.database, schema)
        }
    }

    private func isActive(_ container: DatabaseContainerRef) -> Bool {
        switch container.kind {
        case .database:
            return container.database == context.activeDatabase
        case .schema:
            return container.database == context.activeDatabase && container.schema == context.activeSchema
        }
    }

    private func copyNamesTitle(count: Int) -> String {
        count == 1
            ? String(localized: "Copy Name")
            : String(format: String(localized: "Copy %lld Names"), count)
    }

    private func dropRequest(for targets: [DatabaseContainerRef]) -> DatabaseDropRequest {
        DatabaseDropRequest(
            targets: targets,
            entityName: entityName(for: targets),
            entityNamePlural: entityNamePlural(for: targets),
            dropsDependentObjects: targets.contains { $0.kind == .schema }
        )
    }

    private func entityName(for targets: [DatabaseContainerRef]) -> String {
        targets.contains { $0.kind == .schema } ? schemaEntityName : containerEntityName
    }

    private func entityNamePlural(for targets: [DatabaseContainerRef]) -> String {
        targets.contains { $0.kind == .schema }
            ? PluginManager.shared.schemaEntityNamePlural(for: context.databaseType)
            : PluginManager.shared.containerEntityNamePlural(for: context.databaseType)
    }

    private var dropEligibilityContext: ContainerDropEligibility.Context {
        ContainerDropEligibility.Context(
            activeDatabase: context.activeDatabase,
            activeSchema: context.activeSchema,
            supportsDropDatabase: PluginManager.shared.supportsDropDatabase(for: context.databaseType),
            supportsDropSchema: PluginManager.shared.supportsDropSchema(for: context.databaseType),
            isReadOnly: actions.isReadOnly
        )
    }

    private func foreground(isActive: Bool, isSystem: Bool) -> AnyShapeStyle {
        SidebarRowForeground.style(
            for: SidebarRowForeground.role(
                isEmphasized: isEmphasized,
                isActive: isActive,
                isSystem: isSystem
            )
        )
    }
}
