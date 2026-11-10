//
//  DatabaseTreeNode.swift
//  TablePro
//

import Foundation

/// Which groups a container shows. A group stands for objects the container holds, and a container
/// with nothing to list answers with its own status row instead.
internal enum DatabaseTreeObjectGroupResolver {
    internal static func groups(
        database: String,
        schema: String?,
        itemCounts: [SidebarObjectKind: Int],
        keeping: Set<SidebarObjectKind> = []
    ) -> [DatabaseTreeObjectGroup] {
        SidebarObjectKind.visible(itemCounts: itemCounts, keeping: keeping)
            .map { DatabaseTreeObjectGroup(database: database, schema: schema, kind: $0) }
    }
}

internal extension DatabaseTreeNode.Status {
    /// What a container with nothing to list says, the flat root included. Only the kinds the engine
    /// declares take part, because a fetch the engine never runs stays idle and would hold the row on a
    /// spinner.
    static func emptyContainer(sideStates: [MetadataLoadPhase]) -> DatabaseTreeNode.Status {
        if let failure = sideStates.compactMap(\.failureMessage).first {
            return .error(failure)
        }
        return sideStates.allSatisfy(\.isLoaded) ? .empty : .loading
    }
}

/// Where each side kind's fetch stands for one container. A kind the engine does not declare has no
/// phase, because a fetch the engine never runs stays idle and would read as loading forever.
internal struct DatabaseTreeSidePhases: Equatable {
    let routines: MetadataLoadPhase
    let triggers: MetadataLoadPhase?
    let types: MetadataLoadPhase?

    var all: [MetadataLoadPhase] {
        [routines] + [triggers, types].compactMap { $0 }
    }

    func phase(for category: SidebarObjectCategory) -> MetadataLoadPhase {
        switch category {
        case .table: return .loaded
        case .routine: return routines
        case .trigger: return triggers ?? .loaded
        case .type: return types ?? .loaded
        }
    }

    /// The declared kinds whose fetch failed. Each keeps its group, empty of rows, so the failure shows
    /// where the rows would be: hiding the group would make a list the server refused read as empty.
    func failedKinds(among declared: Set<SidebarObjectKind>) -> Set<SidebarObjectKind> {
        declared.filter { phase(for: $0.category).failureMessage != nil }
    }

    /// The row a group with no rows shows: the failure, or nothing, since a group without rows is
    /// listed only to show a failure or to take filed objects back out of their folders.
    func placeholder(for kind: SidebarObjectKind) -> DatabaseTreeNode.Status? {
        phase(for: kind.category).failureMessage.map(DatabaseTreeNode.Status.error)
    }
}

// NSObject so the outline's item lookups hash the pointer: a plain Swift class looks up a Hashable conformance on
// every hash, about a quarter of opening a section of 17,000 tables.
final class DatabaseTreeNode: NSObject, SidebarOutlineNode {
    enum Status: Equatable {
        case loading
        case empty
        case error(String)
        /// Results are real but incomplete, which `empty` cannot say.
        case truncated(String)
    }

    enum Kind {
        case recentSection
        case recentTable(DatabaseTreeTableRef)
        /// The browsed database's favorite tables, above Recent. Each table also keeps its own row.
        case favoritesSection
        case favoriteTable(DatabaseTreeTableRef)
        case temporarySection
        case temporaryTable(DatabaseTreeTableRef)
        /// Flat shape: the section the browsed schema's folders sit in, above the object kinds.
        case foldersSection
        /// A folder the user files tables and views into. An ordinary container row, never a group
        /// row: it is something the user made, like a group in Xcode's navigator.
        case tableFolder(DatabaseTreeFolderRef)
        case database(DatabaseMetadata)
        case schema(database: String, schema: String)
        case table(DatabaseTreeTableRef)
        /// A partition of a partitioned table. Separate from `.table` because on MySQL and Oracle a
        /// partition is not a relation and cannot be opened, dropped or renamed on its own.
        case partition(DatabaseTreePartitionRef)
        /// A heading under a table for one kind of detail. An ordinary row, not a source list group,
        /// so it indents under its table the way an object group indents under its schema.
        case tableDetailGroup(DatabaseTreeTableDetailGroupRef)
        /// A column, index, foreign key or check. A trigger under a table stays `.trigger`, so it
        /// opens and offers its menu the way it does under a schema.
        case tableDetail(DatabaseTreeTableDetailRef)
        case routine(DatabaseTreeRoutineRef)
        case trigger(DatabaseTreeTriggerRef)
        case userType(DatabaseTreeUserTypeRef)
        case status(Status)

        /// Flat shape: one collapsible section per object kind.
        case objectKindSection(SidebarObjectKind)
        case containerObjectKindSection(DatabaseTreeObjectGroup)
        /// Hierarchical shape: a schema with no database above it.
        case hierarchicalSchemaSection(schema: String)
        /// Flat shape, Redis only.
        case redisKeysSection
        case redisNode(RedisKeyNode)
    }

    let id: String
    var kind: Kind

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
        super.init()
    }

    var isExpandable: Bool {
        switch kind {
        case .recentSection, .favoritesSection, .temporarySection, .foldersSection, .tableFolder, .database, .schema,
             .objectKindSection, .containerObjectKindSection, .tableDetailGroup,
             .hierarchicalSchemaSection, .redisKeysSection:
            return true
        case .table(let ref):
            return ref.table.type == .partitionedTable
        case .partition(let ref):
            return ref.partition.isSubpartitioned
        case .redisNode(let node):
            guard case .namespace = node else { return false }
            return true
        case .recentTable, .favoriteTable, .temporaryTable, .routine, .trigger, .userType, .status, .tableDetail:
            return false
        }
    }

    /// The disclosure a row offers under the sidebar's options, the one rule every expandability gate
    /// reads. `isExpandable` answers for the kind alone, as the outline drew it before Table Details:
    /// partitions shown, details hidden.
    func isExpandable(showsPartitions: Bool, showsTableDetails: Bool) -> Bool {
        switch kind {
        case .table(let ref):
            if showsTableDetails, TableDetailGroupResolver.listsDetails(of: ref.table.type) { return true }
            return showsPartitions && ref.table.type == .partitionedTable
        case .partition:
            return showsPartitions && isExpandable
        default:
            return isExpandable
        }
    }

    /// Whether an Option-click on a row above this one opens it too. With Table Details on, every
    /// table holds groups that each read a list as they open, so a schema of 2,000 tables queued
    /// about 10,000 reads and saved every row it opened. A table and its groups then open only by
    /// their own click; a partitioned table keeps opening with its schema while the option is off.
    func opensWithAncestor(showsTableDetails: Bool) -> Bool {
        switch kind {
        case .table:
            return !showsTableDetails
        case .tableDetailGroup:
            return false
        case .recentSection, .recentTable, .favoritesSection, .favoriteTable, .temporarySection, .temporaryTable, .foldersSection, .tableFolder,
             .database, .schema, .partition, .tableDetail, .routine, .trigger, .userType, .status,
             .objectKindSection, .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection,
             .redisNode:
            return true
        }
    }

    var tableRef: DatabaseTreeTableRef? {
        switch kind {
        case .table(let ref): return ref
        case .partition(let ref): return ref.tableRef
        default: return nil
        }
    }

    var partitionRef: DatabaseTreePartitionRef? {
        if case .partition(let ref) = kind { return ref }
        return nil
    }

    var recentTableRef: DatabaseTreeTableRef? {
        if case .recentTable(let ref) = kind { return ref }
        return nil
    }

    var favoriteTableRef: DatabaseTreeTableRef? {
        if case .favoriteTable(let ref) = kind { return ref }
        return nil
    }

    var temporaryTableRef: DatabaseTreeTableRef? {
        if case .temporaryTable(let ref) = kind { return ref }
        return nil
    }

    /// A source-list group row: chrome the app invented to bucket objects, not an object the
    /// database has. AppKit draws these itself once `isGroupItem` says so, and it stops indenting
    /// their children, which is what puts a table at the same depth as a database in the tree.
    ///
    /// A schema is deliberately not one. It is a real object with its own menu and its own
    /// children, so it stays an ordinary container row the way a folder does in Xcode's navigator.
    var isGroupRow: Bool {
        switch kind {
        case .recentSection, .favoritesSection, .temporarySection, .foldersSection, .objectKindSection,
             .redisKeysSection:
            return true
        case .database, .schema, .containerObjectKindSection, .tableFolder,
             .hierarchicalSchemaSection, .recentTable, .favoriteTable, .temporaryTable, .table, .partition,
             .routine, .trigger, .userType, .status, .redisNode, .tableDetailGroup, .tableDetail:
            return false
        }
    }

    var isContainer: Bool {
        switch kind {
        case .database, .schema:
            return true
        case .recentSection, .recentTable, .favoritesSection, .favoriteTable, .temporarySection, .temporaryTable, .foldersSection, .tableFolder,
             .table, .partition, .routine, .trigger, .userType, .status, .objectKindSection,
             .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection, .redisNode,
             .tableDetailGroup, .tableDetail:
            return false
        }
    }

    func containerRef(systemSchemas: Set<String>) -> DatabaseContainerRef? {
        switch kind {
        case .database(let metadata):
            return .database(metadata.name, isSystem: metadata.isSystemDatabase)
        case .schema(let database, let schema):
            return .schema(database: database, schema: schema, isSystem: systemSchemas.contains(schema))
        case .recentSection, .recentTable, .favoritesSection, .favoriteTable, .temporarySection, .temporaryTable, .foldersSection, .tableFolder,
             .table, .partition, .routine, .trigger, .userType, .status, .objectKindSection,
             .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection, .redisNode,
             .tableDetailGroup, .tableDetail:
            return nil
        }
    }

    var folderRef: DatabaseTreeFolderRef? {
        if case .tableFolder(let ref) = kind { return ref }
        return nil
    }

    static let recentSectionId = "recent-section"
    static let favoritesSectionId = "favorites-section"
    /// The flat shape's root, which has no row of its own; its status row hangs off this id.
    static let flatRootId = "flat-root"
    static let foldersSectionId = "folders-section"
    static func tableFolderId(_ folderId: UUID) -> String { "tablefolder\u{1}\(folderId.uuidString)" }
    static func databaseId(_ database: String) -> String { "db\u{1}\(database)" }
    static func schemaId(database: String, schema: String) -> String { "schema\u{1}\(database)\u{1}\(schema)" }
    static func tableId(_ ref: DatabaseTreeTableRef) -> String {
        plainTableId(ref) ?? "table\u{1}\(ref.id)"
    }

    // The id `ref.id` spells, built in one buffer when no part needs `IdentityPath` escaping.
    private static func plainTableId(_ ref: DatabaseTreeTableRef) -> String? {
        let table = ref.table
        let database = ref.database ?? ""
        let schema = ref.schema ?? ""
        let tableSchema = table.schema ?? ""
        let type = table.type.rawValue
        guard isPlain(database, dots: false), isPlain(schema, dots: false), isPlain(type, dots: false),
              isPlain(tableSchema, dots: true), isPlain(table.name, dots: true)
        else { return nil }
        var id = "table\u{1}"
        id.reserveCapacity(
            id.utf8.count + database.utf8.count + schema.utf8.count + tableSchema.utf8.count
                + table.name.utf8.count + type.utf8.count + 14
        )
        id += database
        id += "|"
        id += schema
        id += "|"
        if !tableSchema.isEmpty {
            id += tableSchema
            id += "."
        }
        id += table.name
        id += "_"
        id += type
        if table.isTemporary { id += "_temporary" }
        return id
    }

    private static func isPlain(_ part: String, dots: Bool) -> Bool {
        !part.utf8.contains { byte in
            byte == UInt8(ascii: "|") || byte == UInt8(ascii: "\\") || (dots && byte == UInt8(ascii: "."))
        }
    }

    static func partitionId(_ ref: DatabaseTreePartitionRef) -> String { "partition\u{1}\(ref.id)" }
    /// Under the table's own id, so a trigger listed under its table and under its schema's Triggers
    /// group is two rows: `NSOutlineView` holds each item once.
    static func tableDetailGroupId(_ group: DatabaseTreeTableDetailGroupRef) -> String {
        "\(tableId(group.table))\u{1}detailgroup\u{1}\(group.kind.rawValue)"
    }

    static func tableDetailId(groupId: String, key: String) -> String {
        "\(groupId)\u{1}detail\u{1}\(key)"
    }

    static func recentTableId(_ ref: DatabaseTreeTableRef) -> String { "recent\u{1}table\u{1}\(ref.id)" }
    static func favoriteTableId(_ ref: DatabaseTreeTableRef) -> String { "favorite\u{1}table\u{1}\(ref.id)" }
    static let temporarySectionId = "temporary-section"
    static func temporaryTableId(_ ref: DatabaseTreeTableRef) -> String { "temporary\u{1}table\u{1}\(ref.id)" }
    static func routineId(_ ref: DatabaseTreeRoutineRef) -> String { "routine\u{1}\(ref.id)" }
    static func triggerId(_ ref: DatabaseTreeTriggerRef) -> String { "trigger\u{1}\(ref.id)" }
    static func userTypeId(_ ref: DatabaseTreeUserTypeRef) -> String { "usertype\u{1}\(ref.id)" }
    static func statusId(parentId: String, status: Status) -> String {
        switch status {
        case .loading: return "\(parentId)\u{1}status.loading"
        case .empty: return "\(parentId)\u{1}status.empty"
        case .error: return "\(parentId)\u{1}status.error"
        case .truncated: return "\(parentId)\u{1}status.truncated"
        }
    }

    static func objectKindSectionId(_ kind: SidebarObjectKind) -> String { "kindSection\u{1}\(kind.rawValue)" }
    static func containerObjectKindSectionId(_ group: DatabaseTreeObjectGroup) -> String {
        "containerKindSection\u{1}\(group.database)\u{1}\(group.schema ?? "")\u{1}\(group.kind.rawValue)"
    }
    static func hierarchicalSchemaSectionId(_ schema: String) -> String { "hschema\u{1}\(schema)" }
    static let redisKeysSectionId = "redis-keys-section"
    static func redisNodeId(_ node: RedisKeyNode) -> String { "redisnode\u{1}\(node.id)" }
}
