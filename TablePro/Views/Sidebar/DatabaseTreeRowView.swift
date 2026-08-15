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
    let showAllTablesMetadata: () -> Void
    let refreshObjectKind: (SidebarObjectKind) -> Void
    let refreshHierarchicalSchema: (String) -> Void
    let openRedisKey: (_ key: String, _ keyType: String) -> Void
    let toggleFavorite: (DatabaseTreeTableRef) -> Void
}

struct DatabaseTreeRowContext {
    let databaseType: DatabaseType
    let activeDatabase: String?
    let activeSchema: String?
    let systemSchemas: Set<String>
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
    /// AppKit sizes the row, but it lays out `NSTableCellView.textField` and `imageView` to do it,
    /// and this cell hosts SwiftUI instead. The size has to reach the content or the text stays one
    /// size inside three different row heights.
    var rowSize: SidebarRowSize = .medium
    var isExternalSchema: @MainActor (String, String) -> Bool = { _, _ in false }
    /// The plugin decides what a table is called, so a section header cannot hardcode "Tables".
    var objectKindTitle: @MainActor (SidebarObjectKind) -> String = { $0.pluralDisplayName }
    var isFavorite: @MainActor (DatabaseTreeTableRef) -> Bool = { _ in false }
}

struct DatabaseTreeRowView: View {
    let node: DatabaseTreeNode
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
            .font(context.rowSize.rowFont)
            .imageScale(.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowContent: some View {
        switch node.kind {
        case .recentSection:
            sectionHeader(String(localized: "Recent"))
        case .recentTable(let ref):
            tableRow(ref)
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
            tableRow(ref)
        case .routine(let ref):
            RoutineRowView(routine: ref.routine)
        case .status(let status):
            statusRow(status)
        case .objectKindSection(let kind):
            sectionHeader(context.objectKindTitle(kind))
        case .hierarchicalSchemaSection(let schema):
            header(
                text: schema,
                systemImage: "folder",
                isActive: schema == context.activeSchema,
                isSystem: false
            )
        case .redisKeysSection:
            sectionHeader(String(localized: "Keys"))
        case .redisNode(let redisNode):
            redisRow(redisNode)
        }
    }

    /// A source list section title carries no icon and no chevron of its own: AppKit draws the
    /// group row's background and its collapse control, and an icon here would be a second glyph
    /// competing with the one on every object below it.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func tableRow(_ ref: DatabaseTreeTableRef) -> some View {
        TableRow(
            table: ref.table,
            isPendingTruncate: context.pendingTruncates.contains(ref.table.name),
            isPendingDelete: context.pendingDeletes.contains(ref.table.name),
            isFavorite: context.isFavorite(ref),
            onToggleFavorite: { actions.toggleFavorite(ref) }
        )
    }

    /// Redis rows carry their own count and type rather than reusing `TableRow`, which is built
    /// around a `TableInfo` a key does not have.
    @ViewBuilder
    private func redisRow(_ node: RedisKeyNode) -> some View {
        switch node {
        case .namespace(let name, _, _, let keyCount):
            Label {
                HStack(spacing: 6) {
                    Text(name)
                        .lineLimit(1)
                    Text(verbatim: "\(keyCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "folder")
            }
        case .key(let name, _, let keyType):
            Label {
                HStack(spacing: 6) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keyType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: RedisKeyNode.iconName(forKeyType: keyType))
            }
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
        .sidebarRowForeground(isActive: isActive, isSystem: isSystem)
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
        case .truncated(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var hasContextMenu: Bool {
        switch node.kind {
        case .status, .recentSection, .redisKeysSection: return false
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
            favoriteButton(for: ref)
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
            Divider()
            favoriteButton(for: ref)
        case .routine(let ref):
            RoutineContextMenu(routine: ref.routine, onShowDDL: actions.showRoutineDDL)
        case .status, .redisKeysSection:
            EmptyView()
        case .objectKindSection(let kind):
            Button(String(format: String(localized: "Show All %@"), context.objectKindTitle(kind))) {
                actions.showAllTablesMetadata()
            }
            .disabled(kind != .table)
            Button(String(localized: "Refresh")) {
                actions.refreshObjectKind(kind)
            }
        case .hierarchicalSchemaSection(let schema):
            Button(String(localized: "Refresh")) {
                actions.refreshHierarchicalSchema(schema)
            }
        case .redisNode(let redisNode):
            redisMenuItems(redisNode)
        }
    }

    /// The star only appears on hover, so the menu is the one route to favouriting that a pointer
    /// can always reach and the only one a keyboard has at all.
    private func favoriteButton(for ref: DatabaseTreeTableRef) -> some View {
        Button(context.isFavorite(ref)
            ? String(localized: "Remove from Favorites")
            : String(localized: "Add to Favorites")) {
            actions.toggleFavorite(ref)
        }
    }

    @ViewBuilder
    private func redisMenuItems(_ node: RedisKeyNode) -> some View {
        switch node {
        case .namespace(_, let fullPrefix, _, _):
            Button(String(localized: "Copy Namespace Prefix")) {
                ClipboardService.shared.writeText(fullPrefix)
            }
        case .key(_, let fullKey, let keyType):
            Button(String(localized: "Copy Key")) {
                ClipboardService.shared.writeText(fullKey)
            }
            Button(String(localized: "Open in New Tab")) {
                actions.openRedisKey(fullKey, keyType)
            }
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
}
