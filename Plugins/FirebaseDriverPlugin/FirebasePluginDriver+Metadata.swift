import Foundation
import TableProFirebaseCore
import TableProPluginKit

extension FirebasePluginDriver {
    /// Subcollections exist per document and Firestore cannot list them all, so they are found by
    /// looking under the first documents of each root collection and offered as collection groups.
    static let groupDiscoveryCollections = 30
    static let groupDiscoveryDocuments = 2
    /// A root with more children than this is a list of records, not of tables, and is browsed
    /// only through `/`.
    static let rootKeyTableLimit = 500
    static let rootTableName = "/"
    static let sampleSize = 50

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        switch variant {
        case .firestore:
            return try await firestoreTables()
        case .realtimeDatabase:
            let keys = try await requireRealtimeDatabase().childKeys("")
            var tables = [PluginTableInfo(name: Self.rootTableName, type: "TABLE", comment: String(localized: "The root of the database"))]
            if keys.count <= Self.rootKeyTableLimit {
                tables += keys.map { PluginTableInfo(name: $0, type: "TABLE") }
            }
            return tables
        }
    }

    private func firestoreTables() async throws -> [PluginTableInfo] {
        let client = try requireFirestore()
        let roots = try await client.listCollectionIds(parent: "")
        let groups = await discoverCollectionGroups(roots: roots, client: client)
        let groupComment = String(localized: "Every collection with this ID, at any depth")
        return roots.map { PluginTableInfo(name: $0, type: "TABLE") }
            + groups.map { PluginTableInfo(name: FirestoreCollectionTarget.groupName($0), type: "TABLE", comment: groupComment) }
    }

    private func discoverCollectionGroups(roots: [String], client: FirestoreClient) async -> [String] {
        let rootSet = Set(roots)
        let found = await withTaskGroup(of: [String].self) { group in
            for root in roots.prefix(Self.groupDiscoveryCollections) {
                group.addTask {
                    let body = FirebaseJSON.object(["structuredQuery": .object([
                        "select": .object(["fields": .array([.object(["fieldPath": .string(FirestoreQueryBuilder.nameField)])])]),
                        "from": .array([.object(["collectionId": .string(root)])]),
                        "limit": .int(Int64(Self.groupDiscoveryDocuments))
                    ])])
                    guard let documents = try? await client.runQuery(parent: "", body: body, operation: root) else { return [] }
                    var ids: [String] = []
                    for document in documents {
                        ids += (try? await client.listCollectionIds(parent: document.path, limit: 100)) ?? []
                    }
                    return ids
                }
            }
            var all: Set<String> = []
            for await ids in group { all.formUnion(ids) }
            return all
        }
        return found.subtracting(rootSet).sorted()
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let sample = try await browse(FirebaseBrowseSpec(table: table, limit: Self.sampleSize, offset: 0))
        let keyColumn = variant == .firestore ? FirebaseColumns.documentName : FirebaseColumns.key
        return zip(sample.columns, sample.columnTypeNames).map { name, type in
            PluginColumnInfo(name: name, dataType: type, isNullable: name != keyColumn, isPrimaryKey: name == keyColumn)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let keyColumn = variant == .firestore ? FirebaseColumns.documentName : FirebaseColumns.key
        return [PluginIndexInfo(name: keyColumn, columns: [keyColumn], isUnique: true, isPrimary: true, type: "PRIMARY KEY")]
    }

    /// Neither engine has a schema, so this describes the fields a sample of documents holds.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let sample = try await browse(FirebaseBrowseSpec(table: table, limit: Self.sampleSize, offset: 0))
        let fields = Dictionary(zip(sample.columns, sample.columnTypeNames).map { ($0, FirebaseJSON.string($1)) },
                                uniquingKeysWith: { first, _ in first })
        let label = variant == .firestore ? "collection" : "path"
        return FirebaseJSON.object([
            label: .string(table),
            "sampledRows": .int(Int64(sample.rows.count)),
            "fields": .object(fields)
        ]).text(pretty: true)
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: serverVersion ?? "Firebase")
    }

    // MARK: - Browse statements

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: nil, queryFilters: [], logicMode: "AND",
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset, columnKinds: [:]
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        let sorts = sortColumns.compactMap { sort -> FirebaseSortSpec? in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            return FirebaseSortSpec(column: columns[sort.columnIndex], ascending: sort.ascending)
        }
        let specs = filters.map { FirebaseFilterSpec(column: $0.column, op: $0.op, value: $0.value, secondValue: $0.secondValue) }
        return FirebaseStatement.encode(FirebaseBrowseSpec(
            table: table, filters: specs, logicMode: logicMode, sorts: sorts, limit: limit, offset: offset
        ))
    }

    // MARK: - Counting

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters filters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        let specs = filters.map { FirebaseFilterSpec(column: $0.column, op: $0.op, value: $0.value, secondValue: $0.secondValue) }
        return try await count(FirebaseBrowseSpec(table: table, filters: specs, logicMode: logicMode, limit: 0, offset: 0))
    }

    func fetchFilteredRowCount(table: String, queryFilters filters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        try await fetchExactRowCount(table: table, schema: nil, queryFilters: filters, logicMode: logicMode)
    }

    /// Firestore counts on the server for one read per thousand documents. The Realtime Database
    /// can only count a node's children without a filter, from its shallow key list.
    func count(_ spec: FirebaseBrowseSpec) async throws -> Int? {
        switch variant {
        case .firestore:
            let client = try requireFirestore()
            let target = try FirestoreCollectionTarget(table: spec.table)
            let types = columnTypes(spec.table)
            let body = try FirestoreQueryBuilder.countQuery(spec: spec, target: target, documentRoot: client.documentRoot,
                                                            typeOf: { types[$0] })
            return try await client.count(parent: target.parentPath, body: body,
                                          operation: String(format: String(localized: "count %@"), spec.table))
        case .realtimeDatabase:
            guard spec.filters.isEmpty else { return nil }
            return try await requireRealtimeDatabase().childKeys(Self.nodePath(spec.table)).count
        }
    }

    static func nodePath(_ table: String) -> String {
        table == rootTableName ? "" : RealtimeDatabasePath.normalized(table)
    }
}
