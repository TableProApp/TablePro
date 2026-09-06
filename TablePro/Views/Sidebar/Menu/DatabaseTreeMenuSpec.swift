//
//  DatabaseTreeMenuSpec.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum DatabaseTreeMenuSpec {
    /// A menu is a list of groups, and every group here is one intent: reach the object, note it,
    /// move its data, change it. The HIG asks for a small number of items in about three groups and
    /// for commands relevant to the clicked object only, so nothing connection-wide belongs on a
    /// row. View Options used to be appended to every menu including every object row, and View ER
    /// Diagram sat in the middle of a table row's clipboard and export commands; both now live on
    /// the empty-area menu, where the thing they act on is the sidebar rather than an object.
    internal static func sections(for context: DatabaseTreeMenuContext) -> [DatabaseTreeMenuSection] {
        guard let clicked = context.clicked else { return backgroundSections(context) }
        switch clicked {
        case .recentTable(let ref):
            return tableSections(ref, context: context, isRecentRow: true) + [
                DatabaseTreeMenuSection([
                    .command(String(localized: "Remove from Recent"), .removeRecent(ref)),
                    .command(String(localized: "Clear Recent Tables"), .clearRecents)
                ])
            ]
        case .table(let ref):
            return tableSections(ref, context: context)
        case .database(let metadata):
            return containerSections(.database(metadata.name, isSystem: metadata.isSystemDatabase), context: context)
        case .schema(let database, let schema):
            return containerSections(
                .schema(database: database, schema: schema, isSystem: context.systemSchemas.contains(schema)),
                context: context
            )
        case .routine(let ref):
            return routineSections(ref)
        case .trigger(let ref):
            return triggerSections(ref)
        case .userType(let ref):
            return userTypeSections(ref)
        case .objectKindSection(let kind):
            return objectKindSections(kind, context: context)
        case .containerObjectKindSection(let group):
            return [
                DatabaseTreeMenuSection([.command(String(localized: "Refresh"), .refreshContainerObjectKind(group))]),
                DatabaseTreeMenuSection(
                    createTypeItems(kind: group.kind, database: group.database, schema: group.schema, context: context)
                )
            ]
        case .hierarchicalSchemaSection(let schema):
            return hierarchicalSchemaSections(schema, context: context)
        case .redisNode(let node):
            return redisSections(node)
        case .status, .recentSection, .redisKeysSection:
            return backgroundSections(context)
        }
    }

    // MARK: - Objects

    private static func tableSections(
        _ ref: DatabaseTreeTableRef,
        context: DatabaseTreeMenuContext,
        isRecentRow: Bool = false
    ) -> [DatabaseTreeMenuSection] {
        /// Narrowed to the clicked row's own database, because a queued Truncate or Drop is
        /// applied by one save against one database. A tree selection can span two of them, and
        /// the second database's tables would then either run in the first or refuse the whole
        /// save; asking for them separately is the honest shape.
        let targets = SidebarMenuTarget
            .resolve(clicked: ref, selection: Array(context.selectedTables))
            .filter { $0.database == ref.database }
        return [
            DatabaseTreeMenuSection(openItems(ref, context: context)),
            DatabaseTreeMenuSection(noteItems(ref, targets: targets, context: context)),
            DatabaseTreeMenuSection(dataItems(ref, targets: targets, context: context)),
            DatabaseTreeMenuSection(writeItems(ref, targets: targets, context: context, isRecentRow: isRecentRow))
        ]
    }

    private static func openItems(
        _ ref: DatabaseTreeTableRef,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = [
            .command(String(localized: "Open in New Tab"), .openInNewTab(ref)),
            .command(String(localized: "Show Structure"), .showStructure(ref))
        ]
        if SidebarContextMenuLogic.isView(clickedTable: ref.table), !context.isReadOnly {
            items.append(.command(String(localized: "Edit View Definition"), .editViewDefinition(ref)))
        }
        return items
    }

    private static func noteItems(
        _ ref: DatabaseTreeTableRef,
        targets: [DatabaseTreeTableRef],
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        let names = targets.map(\.table.name).sorted()
        return [
            .command(copyNamesTitle(count: names.count), .copyTableNames(names)),
            .command(
                context.isFavorite
                    ? String(localized: "Remove from Favorites")
                    : String(localized: "Add to Favorites"),
                .toggleFavorite(ref)
            )
        ]
    }

    /// Everything that moves the object's data somewhere else, in the order the work usually runs:
    /// out of the table, into it, across to another connection, across to another database.
    private static func dataItems(
        _ ref: DatabaseTreeTableRef,
        targets: [DatabaseTreeTableRef],
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        /// Narrowed to the clicked row's own schema as well as its database, which is what Copy To
        /// already did alone. A bare name does not identify a table, so a selection spanning two
        /// schemas handed the dialog names it resolved against one of them.
        let sameScope = targets.filter { $0.qualifyingSchema == ref.qualifyingSchema }
        let names = Set(sameScope.map(\.table.name))
        var items: [DatabaseTreeMenuItem] = [
            .command(String(localized: "Export…"), .exportTables(names: names, ref: ref))
        ]
        if !context.isReadOnly,
           SidebarContextMenuLogic.importVisible(clickedTable: ref.table, supportsImport: context.supportsImport) {
            items += importItems(context.importFormats, ref: ref)
        }
        items.append(.command(String(localized: "Transfer To…"), .transferTables(names: names, ref: ref)))
        if context.canCopyObjects {
            items.append(.command(
                String(localized: "Copy To…"),
                .copyObjectsTo(objects: copySelections(for: sameScope), ref: ref)
            ))
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
        return items
    }

    /// Destructive last, behind its own separator, which is the only way macOS sets one apart:
    /// `NSMenuItem` has no destructive role and Apple does not colour Finder's Move to Trash.
    private static func writeItems(
        _ ref: DatabaseTreeTableRef,
        targets: [DatabaseTreeTableRef],
        context: DatabaseTreeMenuContext,
        isRecentRow: Bool
    ) -> [DatabaseTreeMenuItem] {
        guard !context.isReadOnly else { return [] }
        var items: [DatabaseTreeMenuItem] = []
        if ObjectRenameEligibility.canRename(table: ref.table, context: context.renameEligibility) {
            items.append(.command(String(localized: "Rename"), .beginRenameTable(ref: ref, isRecentRow: isRecentRow)))
        }
        if SidebarContextMenuLogic.truncateVisible(targets: targets) {
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

    private static func routineSections(_ ref: DatabaseTreeRoutineRef) -> [DatabaseTreeMenuSection] {
        var copies: [DatabaseTreeMenuItem] = [.command(String(localized: "Copy Name"), .copyText(ref.routine.name))]
        if let signature = ref.routine.argumentSignature, !signature.isEmpty {
            copies.append(.command(
                String(localized: "Copy with Signature"),
                .copyText(RoutineDisplayLabel.copyableSignature(for: ref.routine))
            ))
        }
        return [
            DatabaseTreeMenuSection(copies),
            DatabaseTreeMenuSection([.command(String(localized: "Show DDL"), .showObjectSource(ref.objectRef))])
        ]
    }

    private static func triggerSections(_ ref: DatabaseTreeTriggerRef) -> [DatabaseTreeMenuSection] {
        var copies: [DatabaseTreeMenuItem] = [.command(String(localized: "Copy Name"), .copyText(ref.trigger.name))]
        if let table = ref.trigger.table, !table.isEmpty {
            copies.append(.command(String(localized: "Copy Table Name"), .copyText(table)))
        }
        return [
            DatabaseTreeMenuSection(copies),
            DatabaseTreeMenuSection([.command(String(localized: "Show DDL"), .showObjectSource(ref.objectRef))])
        ]
    }

    private static func userTypeSections(_ ref: DatabaseTreeUserTypeRef) -> [DatabaseTreeMenuSection] {
        var copies: [DatabaseTreeMenuItem] = [.command(String(localized: "Copy Name"), .copyText(ref.type.name))]
        if ref.type.qualifiedName != ref.type.name {
            copies.append(.command(String(localized: "Copy Qualified Name"), .copyText(ref.type.qualifiedName)))
        }
        return [
            DatabaseTreeMenuSection(copies),
            DatabaseTreeMenuSection([.command(String(localized: "Show Definition"), .showObjectSource(ref.objectRef))])
        ]
    }

    /// Only the Types section offers it, and only where the engine can hand over a template. It is
    /// omitted rather than disabled in read-only mode, the way New View is on the empty-area menu.
    private static func createTypeItems(
        kind: SidebarObjectKind,
        database: String?,
        schema: String?,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        guard kind == .type, context.canCreateType, !context.isReadOnly else { return [] }
        return [.command(String(localized: "New Type…"), .createType(database: database, schema: schema))]
    }

    private static func redisSections(_ node: RedisKeyNode) -> [DatabaseTreeMenuSection] {
        switch node {
        case .namespace(_, let fullPrefix, _, _):
            return [DatabaseTreeMenuSection([
                .command(String(localized: "Copy Namespace Prefix"), .copyRedisNamespacePrefix(fullPrefix))
            ])]
        case .key(_, let fullKey, let keyType):
            return [
                DatabaseTreeMenuSection([
                    .command(String(localized: "Open in New Tab"), .openRedisKey(key: fullKey, keyType: keyType))
                ]),
                DatabaseTreeMenuSection([.command(String(localized: "Copy Key"), .copyRedisKey(fullKey))])
            ]
        }
    }

    private static func objectKindSections(
        _ kind: SidebarObjectKind,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuSection] {
        var items: [DatabaseTreeMenuItem] = []
        if kind == .table {
            let title = context.objectKindTitles[kind] ?? kind.pluralDisplayName
            items.append(.command(
                String(format: String(localized: "Show All %@"), title),
                .showAllTablesMetadata
            ))
        }
        items.append(.command(String(localized: "Refresh"), .refreshObjectKind(kind)))
        return [
            DatabaseTreeMenuSection(items),
            DatabaseTreeMenuSection(createTypeItems(
                kind: kind, database: context.activeDatabase, schema: context.activeSchema, context: context
            ))
        ]
    }

    /// An engine whose tree hangs tables off schemas draws no database rows at all, so its schemas
    /// arrive here rather than as `.schema`. Without this the rename an engine declares and
    /// implements is unreachable on Snowflake and Trino, which are the two that do.
    private static func hierarchicalSchemaSections(
        _ schema: String,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuSection] {
        let ref = DatabaseContainerRef.schema(
            database: context.activeDatabase,
            schema: schema,
            isSystem: context.systemSchemas.contains(schema)
        )
        var writes: [DatabaseTreeMenuItem] = []
        if let renameable = ObjectRenameEligibility.renameable([ref], context: context.renameEligibility) {
            writes.append(.command(renameTitle(for: renameable, context: context), .renameContainer(renameable)))
        }
        return [
            DatabaseTreeMenuSection([.command(String(localized: "Refresh"), .refreshHierarchicalSchema(schema))]),
            /// Oracle, Snowflake, Trino, Dameng and BigQuery draw their schemas here rather than as
            /// container rows, and several of them need a schema-scoped source, so leaving Copy To
            /// on the container path alone put it out of reach on exactly the engines that require it.
            DatabaseTreeMenuSection(copyItems(ref, context: context)),
            DatabaseTreeMenuSection(writes)
        ]
    }

    // MARK: - Containers

    private static func containerSections(
        _ clicked: DatabaseContainerRef,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuSection] {
        let targets = SidebarMenuTarget.resolveContainers(clicked: clicked, selection: context.selectedContainers)
        var open: [DatabaseTreeMenuItem] = []
        /// Omitted rather than disabled: a menu item that can never fire in this state is noise, and
        /// the HIG prefers removing an item that does not apply over showing it greyed out.
        if targets.count == 1, !isActive(clicked, context: context) {
            open.append(.command(useAsActiveTitle(for: clicked, context: context), .useAsActive(clicked)))
        }
        open.append(.command(String(localized: "Refresh"), .refreshContainers(targets)))

        var note: [DatabaseTreeMenuItem] = [.command(copyNamesTitle(count: targets.count), .copyContainerNames(targets))]
        let favoriteDatabases = targets.filter { $0.kind == .database }.compactMap(\.database)
        if !favoriteDatabases.isEmpty {
            note += favoriteDatabaseItems(
                databases: favoriteDatabases,
                state: FavoriteDatabaseSelectionState(
                    environments: favoriteDatabases.map { context.favoriteDatabaseEnvironments[$0] }
                )
            )
        }

        return [
            DatabaseTreeMenuSection(open),
            DatabaseTreeMenuSection(note),
            DatabaseTreeMenuSection(containerDataItems(clicked, targets: targets, context: context)),
            DatabaseTreeMenuSection(containerWriteItems(targets: targets, context: context))
        ]
    }

    private static func containerDataItems(
        _ clicked: DatabaseContainerRef,
        targets: [DatabaseContainerRef],
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = []
        if ExportPreselection.canPreselect(
            containers: targets,
            activeDatabase: context.activeDatabase,
            canReachOtherDatabases: context.canReachOtherDatabases
        ) {
            items.append(.command(String(localized: "Export…"), .exportContainers(targets)))
        }
        /// Offered on a multi-selection where Export is not: `ExportPreselection.canPreselect`
        /// requires every container to share one database, and backing several databases up into
        /// one folder is the whole point of the command.
        let backupDatabases = targets.filter { $0.kind == .database }.compactMap(\.database)
        if context.canBackUp, !backupDatabases.isEmpty {
            items.append(.command(backUpTitle(count: backupDatabases.count), .backUpContainers(backupDatabases)))
        }
        /// Both act on one container: a copy names one source and one target, and a duplicate
        /// names one new database. A multi-selection would need a target per container.
        if targets.count == 1 {
            items += copyItems(clicked, context: context)
        }
        return items
    }

    private static func containerWriteItems(
        targets: [DatabaseContainerRef],
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = []
        if let renameable = ObjectRenameEligibility.renameable(targets, context: context.renameEligibility) {
            items.append(.command(renameTitle(for: renameable, context: context), .renameContainer(renameable)))
        }
        let droppable = ContainerDropEligibility.droppable(targets, context: context.dropEligibility)
        if !droppable.isEmpty {
            items.append(.command(dropTitle(for: droppable, context: context), .dropContainers(droppable)))
        }
        return items
    }

    private static func backUpTitle(count: Int) -> String {
        count == 1
            ? String(localized: "Back Up\u{2026}")
            : String(format: String(localized: "Back Up %lld Databases\u{2026}"), Int64(count))
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
            items.append(.command(FavoriteDatabaseMenu.removeTitle, .removeFavoriteDatabases(databases)))
        }
        return items
    }

    /// Duplicate is offered on a database row alone: a schema is duplicated by copying it into a
    /// schema that exists, which is what Copy To already does, and no engine creates one from a
    /// `CREATE DATABASE`.
    private static func copyItems(
        _ clicked: DatabaseContainerRef,
        context: DatabaseTreeMenuContext
    ) -> [DatabaseTreeMenuItem] {
        var items: [DatabaseTreeMenuItem] = []
        if context.canCopyObjects {
            items.append(.command(String(localized: "Copy To…"), .copyContainerTo(clicked)))
        }
        if clicked.kind == .database, context.canDuplicateDatabase, !clicked.isSystem {
            items.append(.command(String(localized: "Duplicate Database…"), .duplicateDatabase(clicked)))
        }
        return items
    }

    /// A table row's copy carries the whole selection the menu resolved, so right-clicking inside a
    /// multi-selection copies every table in it rather than only the one under the pointer.
    /// Switched over the row's own type rather than asked whether it is a view. A materialized view
    /// answered no and was encoded as a table, which the catalog lists as `.materializedView`, so
    /// the preselection matched nothing and the sheet opened empty. A foreign table is a proxy for
    /// rows on another server and the catalog drops it, so it is not offered.
    private static func copySelections(for targets: [DatabaseTreeTableRef]) -> [ObjectCopySelection] {
        targets.compactMap { target in
            guard let kind = copyKind(for: target.table.type) else { return nil }
            return ObjectCopySelection(kind: kind, name: target.table.name, schema: target.qualifyingSchema)
        }
    }

    private static func copyKind(for type: TableInfo.TableType) -> CompareObjectKind? {
        switch type {
        case .table, .partitionedTable: return .table
        case .view: return .view
        case .materializedView: return .materializedView
        case .foreignTable, .systemTable, .externalTable: return nil
        }
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

    /// The engine's own word for the container, so the item reads "Rename Keyspace" on Cassandra
    /// and "Rename Dataset" on BigQuery. No ellipsis: it opens the row's own field, not a sheet.
    private static func renameTitle(
        for target: DatabaseContainerRef,
        context: DatabaseTreeMenuContext
    ) -> String {
        let entity = target.kind == .schema ? context.schemaEntityName : context.containerEntityName
        return String(format: String(localized: "Rename %@"), entity)
    }

    private static func copyNamesTitle(count: Int) -> String {
        count == 1
            ? String(localized: "Copy Name")
            : String(format: String(localized: "Copy %lld Names"), count)
    }

    // MARK: - Background

    /// The menu for the empty area below the last row, and for the rows that stand for nothing.
    /// It has to produce at least one item: a menu that updates to nothing still shows an empty frame.
    ///
    /// This is where everything scoped to the connection or the sidebar lives, rather than on an
    /// object row: creating an object names no existing one, the diagram is the whole schema, the
    /// database filter and View Options are the sidebar's own state.
    private static func backgroundSections(_ context: DatabaseTreeMenuContext) -> [DatabaseTreeMenuSection] {
        var creation: [DatabaseTreeMenuItem] = []
        if !context.isReadOnly {
            creation.append(.command(String(localized: "New Table…"), .createTable))
            creation.append(.command(String(localized: "New View…"), .createView))
        }
        var filters: [DatabaseTreeMenuItem] = []
        if context.canFilterDatabases {
            filters.append(.command(String(localized: "Filter Databases…"), .filterDatabases))
            if context.hasDatabaseFilter {
                filters.append(.command(String(localized: "Show All Databases"), .showAllDatabases))
            }
        }
        return [
            DatabaseTreeMenuSection(creation),
            DatabaseTreeMenuSection([.command(String(localized: "View ER Diagram"), .showERDiagram)]),
            DatabaseTreeMenuSection(filters),
            DatabaseTreeMenuSection([
                .submenu(title: SidebarViewOptionsMenu.title, sections: SidebarViewOptionsMenu.sections(context))
            ])
        ]
    }
}
