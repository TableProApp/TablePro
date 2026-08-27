//
//  DatabaseTreeMenuSpec.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Everything the object tree's contextual menu depends on, as values.
///
/// `clicked` is nil for a right-click in the empty area below the last row, which `NSOutlineView`
/// reports as `clickedRow == -1`. That case used to produce no menu at all.
internal struct DatabaseTreeMenuContext {
    internal let clicked: DatabaseTreeNode.Kind?
    internal let selectedTables: Set<DatabaseTreeTableRef>
    internal let selectedContainers: [DatabaseContainerRef]
    internal let activeDatabase: String?
    internal let activeSchema: String?
    /// Whether this engine can open a second connection to another database on the server, which
    /// is what lets the export dialog scope itself to a database other than the active one.
    internal let canReachOtherDatabases: Bool
    internal let systemSchemas: Set<String>
    internal let isReadOnly: Bool
    internal let supportsImport: Bool
    internal let importFormats: [ImportFormatOption]
    internal let maintenanceOperations: [String]
    internal let dropEligibility: ContainerDropEligibility.Context
    internal let containerEntityName: String
    internal let containerEntityNamePlural: String
    internal let schemaEntityName: String
    internal let schemaEntityNamePlural: String
    internal let objectKindTitles: [SidebarObjectKind: String]
    internal let isFavorite: Bool
    /// Keyed per database rather than resolved for the clicked row alone, because a right-click
    /// inside a multi-selection acts on the whole selection and those databases need not share a tag.
    internal var favoriteDatabaseEnvironments: [String: FavoriteDatabaseEnvironment] = [:]
    internal let showObjectIcons: Bool
    internal let showObjectComments: Bool
    internal let rowSize: SidebarRowSizePreference
    internal var canFilterDatabases: Bool = false
    internal var hasDatabaseFilter: Bool = false
}

internal enum DatabaseTreeMenuSpec {
    /// Every menu ends with View Options, including a row's. It used to hang off row menus only,
    /// which put it out of reach whenever the list was empty, loading or failed.
    internal static func items(for context: DatabaseTreeMenuContext) -> [DatabaseTreeMenuItem] {
        let rows = rawItems(for: context)
        let viewOptions = DatabaseTreeMenuItem.submenu(
            title: String(localized: "View Options"),
            items: viewOptionItems(context)
        )
        guard !rows.contains(viewOptions) else {
            return DatabaseTreeMenuItem.collapsingSeparators(rows)
        }
        return DatabaseTreeMenuItem.collapsingSeparators(rows + [.separator, viewOptions])
    }

    private static func rawItems(for context: DatabaseTreeMenuContext) -> [DatabaseTreeMenuItem] {
        guard let clicked = context.clicked else { return backgroundItems(context) }
        switch clicked {
        case .recentTable(let ref):
            return tableItems(ref, context: context) + [
                .separator,
                .command(String(localized: "Remove from Recent"), .removeRecent(ref)),
                .command(String(localized: "Clear Recent Tables"), .clearRecents)
            ]
        case .table(let ref):
            return tableItems(ref, context: context)
        case .database(let metadata):
            return containerItems(.database(metadata.name, isSystem: metadata.isSystemDatabase), context: context)
        case .schema(let database, let schema):
            return containerItems(
                .schema(database: database, schema: schema, isSystem: context.systemSchemas.contains(schema)),
                context: context
            )
        case .routine(let ref):
            return routineItems(ref)
        case .trigger(let ref):
            return triggerItems(ref)
        case .objectKindSection(let kind):
            return objectKindItems(kind, context: context)
        case .containerObjectKindSection(let group):
            return [.command(String(localized: "Refresh"), .refreshContainerObjectKind(group))]
        case .hierarchicalSchemaSection(let schema):
            return [.command(String(localized: "Refresh"), .refreshHierarchicalSchema(schema))]
        case .redisNode(let node):
            return redisItems(node)
        case .status, .recentSection, .redisKeysSection:
            return backgroundItems(context)
        }
    }

    // MARK: - Objects

    private static func tableItems(
        _ ref: DatabaseTreeTableRef,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        /// Narrowed to the clicked row's own database, because a queued Truncate or Drop is
        /// applied by one save against one database. A tree selection can span two of them, and
        /// the second database's tables would then either run in the first or refuse the whole
        /// save; asking for them separately is the honest shape.
        let targets = SidebarMenuTarget
            .resolve(clicked: ref, selection: Array(context.selectedTables))
            .filter { $0.database == ref.database }
        let names = targets.map(\.table.name).sorted()
        var items: [DatabaseTreeMenuItem] = [
            .command(String(localized: "Open in New Tab"), .openInNewTab(ref)),
            .command(String(localized: "Show Structure"), .showStructure(ref))
        ]
        if SidebarContextMenuLogic.isView(clickedTable: ref.table), !context.isReadOnly {
            items.append(.command(String(localized: "Edit View Definition"), .editViewDefinition(ref)))
        }
        items.append(.separator)
        items.append(.command(
            context.isFavorite
                ? String(localized: "Remove from Favorites")
                : String(localized: "Add to Favorites"),
            .toggleFavorite(ref)
        ))
        items.append(.separator)
        items.append(.command(copyNamesTitle(count: names.count), .copyTableNames(names)))
        items.append(.command(String(localized: "Export…"), .exportTables(names: Set(names), ref: ref)))
        items.append(.command(String(localized: "View ER Diagram"), .showERDiagram))

        if !context.isReadOnly,
           SidebarContextMenuLogic.importVisible(clickedTable: ref.table, supportsImport: context.supportsImport) {
            items += importItems(context.importFormats, ref: ref)
        }

        if SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: context.isReadOnly,
            hasSelection: true,
            supportedOperations: context.maintenanceOperations
        ) {
            items.append(.submenu(
                title: String(localized: "Maintenance"),
                items: context.maintenanceOperations.map { operation in
                    .command(operation, .maintenance(operation: operation, tableName: ref.table.name, ref: ref))
                }
            ))
        }

        guard !context.isReadOnly else { return items }
        items.append(.separator)
        items.append(.command(String(localized: "Create New View…"), .createView))
        if SidebarContextMenuLogic.truncateVisible(clickedTable: ref.table) {
            items.append(.command(String(localized: "Truncate"), .truncateTables(targets: targets, ref: ref)))
        }
        items.append(.command(
            SidebarContextMenuLogic.deleteLabel(for: ref.table.type),
            .dropTables(targets: targets, ref: ref)
        ))
        return items
    }

    /// One format is a plain item, several are a submenu, matching what the menu bar's own Import
    /// command does rather than inventing a second shape for the sidebar.
    private static func importItems(
        _ formats: [ImportFormatOption],
        ref: DatabaseTreeTableRef
    ) -> [DatabaseTreeMenuItem] {
        guard !formats.isEmpty else { return [] }
        if formats.count == 1, let only = formats.first {
            return [.command(only.standaloneLabel, .importTables(formatId: only.id, ref: ref))]
        }
        return [.submenu(
            title: String(localized: "Import"),
            items: formats.map { .command($0.submenuLabel, .importTables(formatId: $0.id, ref: ref)) }
        )]
    }

    private static func routineItems(_ ref: DatabaseTreeRoutineRef) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = [.command(String(localized: "Copy Name"), .copyText(ref.routine.name))]
        if let signature = ref.routine.argumentSignature, !signature.isEmpty {
            items.append(.command(
                String(localized: "Copy with Signature"),
                .copyText(RoutineDisplayLabel.copyableSignature(for: ref.routine))
            ))
        }
        items.append(.separator)
        items.append(.command(String(localized: "Show DDL"), .showObjectSource(ref.objectRef)))
        return items
    }

    private static func triggerItems(_ ref: DatabaseTreeTriggerRef) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = [.command(String(localized: "Copy Name"), .copyText(ref.trigger.name))]
        if let table = ref.trigger.table, !table.isEmpty {
            items.append(.command(String(localized: "Copy Table Name"), .copyText(table)))
        }
        items.append(.separator)
        items.append(.command(String(localized: "Show DDL"), .showObjectSource(ref.objectRef)))
        return items
    }

    private static func redisItems(_ node: RedisKeyNode) -> [DatabaseTreeMenuItem] {
        switch node {
        case .namespace(_, let fullPrefix, _, _):
            return [.command(String(localized: "Copy Namespace Prefix"), .copyRedisNamespacePrefix(fullPrefix))]
        case .key(_, let fullKey, let keyType):
            return [
                .command(String(localized: "Copy Key"), .copyRedisKey(fullKey)),
                .command(String(localized: "Open in New Tab"), .openRedisKey(key: fullKey, keyType: keyType))
            ]
        }
    }

    private static func objectKindItems(
        _ kind: SidebarObjectKind,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = []
        if kind == .table {
            let title = context.objectKindTitles[kind] ?? kind.pluralDisplayName
            items.append(.command(
                String(format: String(localized: "Show All %@"), title),
                .showAllTablesMetadata
            ))
        }
        items.append(.command(String(localized: "Refresh"), .refreshObjectKind(kind)))
        return items
    }

    // MARK: - Containers

    private static func containerItems(
        _ clicked: DatabaseContainerRef,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        let targets = SidebarMenuTarget.resolveContainers(clicked: clicked, selection: context.selectedContainers)
        let droppable = ContainerDropEligibility.droppable(targets, context: context.dropEligibility)
        var items: [DatabaseTreeMenuItem] = []

        /// Omitted rather than disabled: a menu item that can never fire in this state is noise, and
        /// the HIG prefers removing an item that does not apply over showing it greyed out.
        if targets.count == 1, !isActive(clicked, context: context) {
            items.append(.command(useAsActiveTitle(for: clicked, context: context), .useAsActive(clicked)))
        }
        items.append(.command(String(localized: "Refresh"), .refreshContainers(targets)))
        items.append(.command(copyNamesTitle(count: targets.count), .copyContainerNames(targets)))

        let favoriteDatabases = targets.filter { $0.kind == .database }.compactMap(\.database)
        if !favoriteDatabases.isEmpty {
            let favoriteItems = favoriteDatabaseItems(
                databases: favoriteDatabases,
                state: FavoriteDatabaseSelectionState(
                    environments: favoriteDatabases.map { context.favoriteDatabaseEnvironments[$0] }
                )
            )
            if !favoriteItems.isEmpty {
                items.append(.separator)
                items += favoriteItems
            }
        }

        if ExportPreselection.canPreselect(
            containers: targets,
            activeDatabase: context.activeDatabase,
            canReachOtherDatabases: context.canReachOtherDatabases
        ) {
            items.append(.separator)
            items.append(.command(String(localized: "Export…"), .exportContainers(targets)))
        }
        guard !droppable.isEmpty else { return items }
        items.append(.separator)
        items.append(.command(dropTitle(for: droppable, context: context), .dropContainers(droppable)))
        return items
    }

    private static func favoriteDatabaseItems(
        databases: [String],
        state: FavoriteDatabaseSelectionState
    ) -> [DatabaseTreeMenuItem] {
        guard !state.isEmpty else { return [] }
        let environmentItems: [DatabaseTreeMenuItem] = FavoriteDatabaseMenu.environmentItems(for: state)
            .map { item in
                .command(SidebarMenuEntry(
                    title: item.title,
                    command: .setFavoriteDatabases(databases: databases, environment: item.environment),
                    isOn: item.isOn
                ))
            }
        var items: [DatabaseTreeMenuItem] = [
            .submenu(title: FavoriteDatabaseMenu.submenuTitle(for: state), items: environmentItems)
        ]
        if state.hasFavorite {
            items.append(.destructive(FavoriteDatabaseMenu.removeTitle, .removeFavoriteDatabases(databases)))
        }
        return items
    }

    private static func isActive(_ container: DatabaseContainerRef, context: DatabaseTreeMenuContext) -> Bool {
        switch container.kind {
        case .database:
            return container.database == context.activeDatabase
        case .schema:
            return container.database == context.activeDatabase && container.schema == context.activeSchema
        }
    }

    private static func useAsActiveTitle(
        for container: DatabaseContainerRef,
        context: DatabaseTreeMenuContext
    ) -> String {
        String(
            format: String(localized: "Use as Active %@"),
            container.kind == .schema ? context.schemaEntityName : context.containerEntityName
        )
    }

    private static func dropTitle(
        for targets: [DatabaseContainerRef],
        context: DatabaseTreeMenuContext
    ) -> String {
        let isSchema = targets.contains { $0.kind == .schema }
        return DatabaseDropRequest(
            targets: targets,
            entityName: isSchema ? context.schemaEntityName : context.containerEntityName,
            entityNamePlural: isSchema ? context.schemaEntityNamePlural : context.containerEntityNamePlural,
            dropsDependentObjects: isSchema
        ).menuTitle
    }

    private static func copyNamesTitle(count: Int) -> String {
        count == 1
            ? String(localized: "Copy Name")
            : String(format: String(localized: "Copy %lld Names"), count)
    }

    // MARK: - Background

    /// The menu for the empty area below the last row, and for the rows that stand for nothing.
    /// It has to produce at least one item: a menu that updates to nothing still shows an empty frame.
    private static func backgroundItems(_ context: DatabaseTreeMenuContext) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = []
        if !context.isReadOnly {
            items.append(.command(String(localized: "New Table…"), .createTable))
            items.append(.command(String(localized: "New View…"), .createView))
            items.append(.separator)
        }
        items.append(.command(String(localized: "View ER Diagram"), .showERDiagram))
        if context.canFilterDatabases {
            items.append(.separator)
            items.append(.command(String(localized: "Filter Databases…"), .filterDatabases))
            if context.hasDatabaseFilter {
                items.append(.command(String(localized: "Show All Databases"), .showAllDatabases))
            }
        }
        items.append(.separator)
        items.append(.submenu(title: String(localized: "View Options"), items: viewOptionItems(context)))
        return items
    }

    /// Reachable from every menu, including the empty-area one, because it was previously nested in
    /// a row's menu and so disappeared entirely whenever the sidebar was empty, loading or failed.
    internal static func viewOptionItems(_ context: DatabaseTreeMenuContext) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = [
            .command(SidebarMenuEntry(
                title: String(localized: "Icons"),
                command: .toggleObjectIcons,
                isOn: context.showObjectIcons
            )),
            .command(SidebarMenuEntry(
                title: String(localized: "Comments"),
                command: .toggleObjectComments,
                isOn: context.showObjectComments
            )),
            .separator
        ]
        items += SidebarRowSizePreference.allCases.map { size in
            .command(SidebarMenuEntry(
                title: size.title,
                command: .setRowSize(size),
                isOn: context.rowSize == size
            ))
        }
        return items
    }
}
