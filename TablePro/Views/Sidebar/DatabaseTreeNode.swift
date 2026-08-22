//
//  DatabaseTreeNode.swift
//  TablePro
//

import Foundation

/// Which groups a container shows. A group stands for objects the container holds, and a container
/// with nothing in it answers with its own status row instead, so it lists no empty group at all.
internal enum DatabaseTreeObjectGroupResolver {
    internal static func groups(
        database: String,
        schema: String?,
        itemCounts: [SidebarObjectKind: Int],
        declaredKinds: Set<SidebarObjectKind> = []
    ) -> [DatabaseTreeObjectGroup] {
        SidebarObjectKind.visible(
            itemCounts: itemCounts,
            declaredKinds: declaredKinds,
            includingEmptyTables: false
        )
        .map { DatabaseTreeObjectGroup(database: database, schema: schema, kind: $0) }
    }
}

final class DatabaseTreeNode: SidebarOutlineNode {
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
        case database(DatabaseMetadata)
        case schema(database: String, schema: String)
        case table(DatabaseTreeTableRef)
        case routine(DatabaseTreeRoutineRef)
        case trigger(DatabaseTreeTriggerRef)
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
    }

    var isExpandable: Bool {
        switch kind {
        case .recentSection, .database, .schema,
             .objectKindSection, .containerObjectKindSection,
             .hierarchicalSchemaSection, .redisKeysSection:
            return true
        case .table(let ref):
            return ref.table.type == .partitionedTable
        case .redisNode(let node):
            guard case .namespace = node else { return false }
            return true
        case .recentTable, .routine, .trigger, .status:
            return false
        }
    }

    var tableRef: DatabaseTreeTableRef? {
        if case .table(let ref) = kind { return ref }
        return nil
    }

    var recentTableRef: DatabaseTreeTableRef? {
        if case .recentTable(let ref) = kind { return ref }
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
        case .recentSection, .objectKindSection, .redisKeysSection:
            return true
        case .database, .schema, .containerObjectKindSection,
             .hierarchicalSchemaSection, .recentTable, .table,
             .routine, .trigger, .status, .redisNode:
            return false
        }
    }

    var isContainer: Bool {
        switch kind {
        case .database, .schema:
            return true
        case .recentSection, .recentTable, .table, .routine, .trigger, .status,
             .objectKindSection, .containerObjectKindSection,
             .hierarchicalSchemaSection, .redisKeysSection, .redisNode:
            return false
        }
    }

    func containerRef(systemSchemas: Set<String>) -> DatabaseContainerRef? {
        switch kind {
        case .database(let metadata):
            return .database(metadata.name, isSystem: metadata.isSystemDatabase)
        case .schema(let database, let schema):
            return .schema(database: database, schema: schema, isSystem: systemSchemas.contains(schema))
        case .recentSection, .recentTable, .table, .routine, .trigger, .status,
             .objectKindSection, .containerObjectKindSection,
             .hierarchicalSchemaSection, .redisKeysSection, .redisNode:
            return nil
        }
    }

    static let recentSectionId = "recent-section"
    static func databaseId(_ database: String) -> String { "db\u{1}\(database)" }
    static func schemaId(database: String, schema: String) -> String { "schema\u{1}\(database)\u{1}\(schema)" }
    static func tableId(_ ref: DatabaseTreeTableRef) -> String { "table\u{1}\(ref.id)" }
    static func recentTableId(_ ref: DatabaseTreeTableRef) -> String { "recent\u{1}table\u{1}\(ref.id)" }
    static func routineId(_ ref: DatabaseTreeRoutineRef) -> String { "routine\u{1}\(ref.id)" }
    static func triggerId(_ ref: DatabaseTreeTriggerRef) -> String { "trigger\u{1}\(ref.id)" }
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
