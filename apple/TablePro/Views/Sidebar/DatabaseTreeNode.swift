//
//  DatabaseTreeNode.swift
//  TablePro
//

import Foundation

// A group stands for objects the container holds; a container with nothing to list shows its own status row.
internal enum DatabaseTreeObjectGroupResolver {
    internal static func groups(
        database: String,
        schema: String?,
        itemCounts: [SidebarObjectKind: Int],
        keeping: Set<SidebarObjectKind> = [],
        declared: [SidebarServerObjectKind] = []
    ) -> [DatabaseTreeObjectGroup] {
        SidebarObjectKind.visible(itemCounts: itemCounts, keeping: keeping, declared: declared)
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

// An undeclared kind has no phase: a fetch the engine never runs stays idle and would read as loading forever.
internal struct DatabaseTreeSidePhases: Equatable {
    let routines: MetadataLoadPhase
    let triggers: MetadataLoadPhase?
    let types: MetadataLoadPhase?
    // Keyed by kind id, holding only the declared kinds this container lists.
    let serverObjects: [String: MetadataLoadPhase]

    init(
        routines: MetadataLoadPhase,
        triggers: MetadataLoadPhase?,
        types: MetadataLoadPhase?,
        serverObjects: [String: MetadataLoadPhase] = [:]
    ) {
        self.routines = routines
        self.triggers = triggers
        self.types = types
        self.serverObjects = serverObjects
    }

    var all: [MetadataLoadPhase] {
        [routines] + [triggers, types].compactMap { $0 } + serverObjects.keys.sorted().compactMap { serverObjects[$0] }
    }

    func phase(for kind: SidebarObjectKind) -> MetadataLoadPhase {
        switch kind.category {
        case .table: return .loaded
        case .routine: return routines
        case .trigger: return triggers ?? .loaded
        case .type: return types ?? .loaded
        case .server: return kind.serverKind.flatMap { serverObjects[$0.id] } ?? .loaded
        }
    }

    // A failed kind keeps its group, so a list the server refused never reads as empty.
    func failedKinds(among declared: Set<SidebarObjectKind>) -> Set<SidebarObjectKind> {
        declared.filter { phase(for: $0).failureMessage != nil }
    }

    // A group without rows is listed only for a failure or to take filed objects back out of their folders.
    func placeholder(for kind: SidebarObjectKind) -> DatabaseTreeNode.Status? {
        phase(for: kind).failureMessage.map(DatabaseTreeNode.Status.error)
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
        case routine(DatabaseTreeRoutineRef)
        case trigger(DatabaseTreeTriggerRef)
        case userType(DatabaseTreeUserTypeRef)
        case serverObject(DatabaseTreeServerObjectRef)
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
        case .recentSection, .temporarySection, .foldersSection, .tableFolder, .database, .schema,
             .objectKindSection, .containerObjectKindSection,
             .hierarchicalSchemaSection, .redisKeysSection:
            return true
        case .table(let ref):
            return ref.table.type == .partitionedTable
        case .partition(let ref):
            return ref.partition.isSubpartitioned
        case .redisNode(let node):
            guard case .namespace = node else { return false }
            return true
        case .recentTable, .temporaryTable, .routine, .trigger, .userType, .serverObject, .status:
            return false
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

    var temporaryTableRef: DatabaseTreeTableRef? {
        if case .temporaryTable(let ref) = kind { return ref }
        return nil
    }

    // Chrome the app invented to bucket objects; a schema is a real object, so it stays an ordinary container row.
    var isGroupRow: Bool {
        switch kind {
        case .recentSection, .temporarySection, .foldersSection, .objectKindSection, .redisKeysSection:
            return true
        case .database, .schema, .containerObjectKindSection, .tableFolder,
             .hierarchicalSchemaSection, .recentTable, .temporaryTable, .table, .partition,
             .routine, .trigger, .userType, .serverObject, .status, .redisNode:
            return false
        }
    }

    var isContainer: Bool {
        switch kind {
        case .database, .schema:
            return true
        case .recentSection, .recentTable, .temporarySection, .temporaryTable, .foldersSection, .tableFolder,
             .table, .partition, .routine, .trigger, .userType, .serverObject, .status, .objectKindSection,
             .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection, .redisNode:
            return false
        }
    }

    func containerRef(systemSchemas: Set<String>) -> DatabaseContainerRef? {
        switch kind {
        case .database(let metadata):
            return .database(metadata.name, isSystem: metadata.isSystemDatabase)
        case .schema(let database, let schema):
            return .schema(database: database, schema: schema, isSystem: systemSchemas.contains(schema))
        case .recentSection, .recentTable, .temporarySection, .temporaryTable, .foldersSection, .tableFolder,
             .table, .partition, .routine, .trigger, .userType, .serverObject, .status, .objectKindSection,
             .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection, .redisNode:
            return nil
        }
    }

    var folderRef: DatabaseTreeFolderRef? {
        if case .tableFolder(let ref) = kind { return ref }
        return nil
    }

    static let recentSectionId = "recent-section"
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
    static func recentTableId(_ ref: DatabaseTreeTableRef) -> String { "recent\u{1}table\u{1}\(ref.id)" }
    static let temporarySectionId = "temporary-section"
    static func temporaryTableId(_ ref: DatabaseTreeTableRef) -> String { "temporary\u{1}table\u{1}\(ref.id)" }
    static func routineId(_ ref: DatabaseTreeRoutineRef) -> String { "routine\u{1}\(ref.id)" }
    static func triggerId(_ ref: DatabaseTreeTriggerRef) -> String { "trigger\u{1}\(ref.id)" }
    static func userTypeId(_ ref: DatabaseTreeUserTypeRef) -> String { "usertype\u{1}\(ref.id)" }
    static func serverObjectId(_ ref: DatabaseTreeServerObjectRef) -> String { "serverobject\u{1}\(ref.id)" }
    static func statusId(parentId: String, status: Status) -> String {
        switch status {
        case .loading: return "\(parentId)\u{1}status.loading"
        case .empty: return "\(parentId)\u{1}status.empty"
        case .error: return "\(parentId)\u{1}status.error"
        case .truncated: return "\(parentId)\u{1}status.truncated"
        }
    }

    static func objectKindSectionId(_ kind: SidebarObjectKind) -> String { "kindSection\u{1}\(kind.persistenceName)" }
    static func containerObjectKindSectionId(_ group: DatabaseTreeObjectGroup) -> String {
        "containerKindSection\u{1}\(group.database)\u{1}\(group.schema ?? "")\u{1}\(group.kind.persistenceName)"
    }
    static func hierarchicalSchemaSectionId(_ schema: String) -> String { "hschema\u{1}\(schema)" }
    static let redisKeysSectionId = "redis-keys-section"
    static func redisNodeId(_ node: RedisKeyNode) -> String { "redisnode\u{1}\(node.id)" }
}
