//
//  CompareMetadataService.swift
//  TablePro
//
//  Every driver call the comparison makes.
//
//  It exists because the session used to reach `DatabaseManager.shared.driver(for:)`
//  directly, which hands back the connection's single live interactive driver.
//  That driver carries mutable position, so a read taken without
//  `SessionDriverGate` can interleave with a tab's query or land on whichever
//  database that tab last switched to, and it skips `metadataRoute`, which is
//  what keeps an embedded engine from being handed a second, empty instance.
//  `withMetadataDriver(scope:)` is the one route that applies both.
//
//  The closure hands back the app-level `DatabaseDriver`; the comparison needs
//  the plugin transfer types, so the downcast happens inside the gated closure,
//  the same shape `DatabaseManager+Schema` already uses.
//

import Foundation
import os
import TableProPluginKit

/// One table's raw metadata, in transfer types so it can cross the gated closure. Conversion to
/// `TableStructureSnapshot` happens on the caller's side, where the editable definition types live.
internal struct TableStructureRead: Sendable {
    internal let table: PluginTableInfo
    internal let columns: [PluginColumnInfo]
    internal let indexes: [PluginIndexInfo]
    internal let foreignKeys: [PluginForeignKeyInfo]
    internal let metadata: PluginTableMetadata?
    internal let failure: String?

    internal var snapshot: TableStructureSnapshot? {
        guard failure == nil else { return nil }
        return TableStructureSnapshot.from(
            table: table, columns: columns, indexes: indexes, foreignKeys: foreignKeys, metadata: metadata
        )
    }
}

internal struct RoutineSourceRead: Sendable {
    internal let name: String
    internal let kind: CompareObjectKind
    internal let schema: String?
    internal let signature: String?
    internal let source: String
}

@MainActor
internal struct CompareMetadataService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CompareMetadataService")

    private let manager: DatabaseManager

    internal init(manager: DatabaseManager = .shared) {
        self.manager = manager
    }

    // MARK: - Scope discovery

    internal func databases(for connection: DatabaseConnection) async throws -> [String] {
        try await manager.ensureConnected(connection)
        let scope = DatabaseScope(connectionId: connection.id, database: connection.database ?? "", schema: nil)
        return try await manager.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchDatabases()
        }
    }

    internal func schemas(for endpoint: DatabaseEndpoint, connection: DatabaseConnection) async throws -> [String] {
        try await manager.ensureConnected(connection)
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            try await driver.fetchSchemas()
        }
    }

    // MARK: - Capability

    internal func refusalReason(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        mode: CompareSyncMode
    ) async throws -> String? {
        try await manager.ensureConnected(connection)
        let name = endpoint.qualifiedDescription
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else {
                return String(
                    format: String(localized: "%@ cannot be compared, because its driver does not expose metadata."),
                    name
                )
            }
            return CompareSyncEligibility.refusalReason(for: plugin, mode: mode, endpointName: name)
        }
    }

    // MARK: - Structure

    /// One object's failure is that object's, not the comparison's. A single unreadable table used
    /// to abort the whole run, which is why `TableDiffResult.comparisonError` was read by the UI and
    /// written by nothing.
    ///
    /// `names` narrows the read to the objects the caller already knows it wants, matched without
    /// regard to case because engines disagree on identifier folding. A comparison passes nil and
    /// reads the whole scope; a copy of one table would otherwise pay four round trips for every
    /// other table in the database.
    ///
    /// `profile` says which of the four reads this caller actually looks at. A data comparison
    /// pairs tables and reads their rows, so the indexes and the table metadata it used to fetch
    /// for every table were two round trips per table spent on fields it never reads.
    internal func tableReads(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        includeViews: Bool,
        profile: TableReadProfile = .structure,
        names: Set<String>? = nil
    ) async throws -> [TableStructureRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        let databaseType = endpoint.databaseType
        let wanted = names.map { Set($0.map { $0.lowercased() }) }

        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            let tables = try await plugin.fetchTables(schema: schema).filter { table in
                guard wanted?.contains(table.name.lowercased()) ?? true else { return false }
                let kind = CompareTableKindClassifier.kind(of: table)
                return kind == .table || includeViews
            }
            return try await Self.read(
                tables: tables, schema: schema, profile: profile,
                narrowed: wanted != nil, databaseType: databaseType, using: plugin
            )
        }
    }

    /// Both sides at once.
    ///
    /// A comparison is two independent reads and used to run them one after the other, so the wall
    /// clock was the sum of the two. `SessionDriverGate` is a FIFO queue per connection rather than
    /// a lock a task can deadlock itself on, and these two reads are concurrent rather than nested,
    /// so the worst case where both sides route to one connection's shared driver is that they
    /// serialise, which is what they did before.
    internal func bothSideTableReads(
        context: CompareRunner.Context,
        includeViews: Bool,
        profile: TableReadProfile
    ) async throws -> (source: [TableStructureRead], target: [TableStructureRead]) {
        async let source = tableReads(
            for: context.source, connection: context.sourceConnection, includeViews: includeViews, profile: profile
        )
        async let target = tableReads(
            for: context.target, connection: context.targetConnection, includeViews: includeViews, profile: profile
        )
        return try await (source, target)
    }

    /// `fetchRoutines` supersedes the old per-kind pair and carries `identity`, which is what
    /// `fetchRoutineDDL` needs to address an overloaded routine again. A routine whose DDL cannot
    /// be read is still listed, with an empty definition, so it shows as present rather than
    /// vanishing from the comparison.
    internal func routineReads(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection
    ) async throws -> [RoutineSourceRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            let routines = (try? await plugin.fetchRoutines(schema: schema)) ?? []
            var reads: [RoutineSourceRead] = []
            for routine in routines {
                try Task.checkCancellation()
                var source = routine.definition ?? ""
                if source.isEmpty {
                    source = (try? await plugin.fetchRoutineDDL(routine)) ?? ""
                }
                reads.append(RoutineSourceRead(
                    name: routine.name,
                    kind: routine.kind == .procedure ? .procedure : .function,
                    schema: routine.schema ?? schema,
                    signature: routine.argumentSignature,
                    source: source
                ))
            }
            return reads
        }
    }

    /// A trigger on a table that is not in scope is not in scope either, so the tables the
    /// structure read already listed are the ones kept.
    ///
    /// The whole-schema read is one query where the driver has one. Where it does not, the
    /// protocol's default answers with nothing rather than looping, so the per-table read is the
    /// only correct fallback and `providesBulkTriggerFetch` is what tells the two apart.
    internal func triggerReads(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        tables: [String]
    ) async throws -> [RoutineSourceRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        let inScope = Set(tables.map { $0.lowercased() })
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            guard plugin.providesBulkTriggerFetch else {
                return try await Self.perTableTriggerReads(tables: tables, schema: schema, using: plugin)
            }
            /// A failed whole-schema query is not an answer of "no triggers". Swallowing it made an
            /// empty set authoritative on one side, so every trigger on the other side read as a
            /// real difference and the script offered to drop or create all of them.
            let triggers: [PluginTriggerInfo]
            do {
                triggers = try await plugin.fetchAllTriggers(schema: schema)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.warning(
                    "Whole-schema trigger read failed, falling back per table: \(error.localizedDescription, privacy: .public)"
                )
                return try await Self.perTableTriggerReads(tables: tables, schema: schema, using: plugin)
            }
            return triggers
                .filter { trigger in
                    guard let table = trigger.table?.lowercased() else { return true }
                    return inScope.contains(table)
                }
                .map { Self.read($0, schema: schema, fallbackTable: nil) }
        }
    }

    nonisolated private static func perTableTriggerReads(
        tables: [String],
        schema: String?,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [RoutineSourceRead] {
        var reads: [RoutineSourceRead] = []
        for table in tables {
            try Task.checkCancellation()
            guard let triggers = try? await plugin.fetchTriggers(table: table, schema: schema) else { continue }
            reads += triggers.map { read($0, schema: schema, fallbackTable: table) }
        }
        return reads
    }

    nonisolated private static func read(
        _ trigger: PluginTriggerInfo,
        schema: String?,
        fallbackTable: String?
    ) -> RoutineSourceRead {
        RoutineSourceRead(
            name: trigger.name,
            kind: .trigger,
            schema: trigger.schema ?? schema,
            signature: trigger.table ?? fallbackTable,
            source: trigger.definition ?? trigger.statement
        )
    }

    internal func viewDefinitions(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        views: [PluginTableInfo]
    ) async throws -> [RoutineSourceRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            var reads: [RoutineSourceRead] = []
            for view in views {
                try Task.checkCancellation()
                let definition = try? await plugin.fetchViewDefinition(
                    view: view.name, schema: view.schema ?? schema
                )
                let source = definition ?? ""
                reads.append(RoutineSourceRead(
                    name: view.name,
                    kind: CompareTableKindClassifier.kind(of: view),
                    schema: view.schema ?? schema,
                    signature: nil,
                    source: source
                ))
            }
            return reads
        }
    }

    // MARK: - Helpers

    /// Reads a whole scope, asking each driver for the cheapest form of every read it needs.
    ///
    /// The per-table form costs four round trips per table, which is what made a 200-table
    /// comparison 800 round trips a side. `PluginDatabaseDriver` already answers three of the four
    /// for a whole schema in one query, and now answers the fourth, so a driver that declares them
    /// is read in a handful of statements no matter how many tables it holds.
    ///
    /// The fan-out this replaces bought nothing. `withMetadataDriver` yields one driver, and a
    /// driver dispatches its statements onto its own serial queue, so four concurrent reads of one
    /// connection queue behind each other. Its gate was `supportsConnectionPooling`, which answers
    /// whether a *second* connection is safe, not whether one connection can run two statements.
    ///
    /// `narrowed` says the caller asked for specific tables, so the whole-schema queries would read
    /// the rest of the database to throw it away. Those callers keep the per-table reads.
    nonisolated internal static func read(
        tables: [PluginTableInfo],
        schema: String?,
        profile: TableReadProfile,
        narrowed: Bool,
        databaseType: DatabaseType,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [TableStructureRead] {
        let bulk = narrowed
            ? BulkMetadata()
            : await BulkMetadata(schema: schema, profile: profile, tables: tables, plugin: plugin)

        /// Whatever the whole-schema reads did not answer is still one statement per table, and a
        /// driver whose statements are independent requests rather than one serialised socket can
        /// overlap them. Cloudflare D1 is the case that matters: it has only the bulk foreign-key
        /// read, so everything else would otherwise be three remote calls per table in a row.
        /// A driver that cannot take a second connection stays serial, which is the gate the
        /// previous fan-out used and the conservative answer for a driver with no queue of its own.
        let concurrency = bulk.answersEveryRead(for: profile) || !databaseType.supportsConnectionPooling
            ? 1
            : Self.fallbackConcurrency

        return try await map(tables, concurrency: concurrency) { table in
            await read(table: table, schema: table.schema ?? schema, profile: profile, bulk: bulk, using: plugin)
        }
    }

    nonisolated private static let fallbackConcurrency = 4

    nonisolated private static func map(
        _ tables: [PluginTableInfo],
        concurrency: Int,
        _ transform: @escaping @Sendable (PluginTableInfo) async -> TableStructureRead
    ) async throws -> [TableStructureRead] {
        guard concurrency > 1, tables.count > 1 else {
            var results: [TableStructureRead] = []
            results.reserveCapacity(tables.count)
            for table in tables {
                try Task.checkCancellation()
                results.append(await transform(table))
            }
            return results
        }

        return try await withThrowingTaskGroup(of: (Int, TableStructureRead).self) { group in
            var results = [TableStructureRead?](repeating: nil, count: tables.count)
            var next = 0

            while next < tables.count, next < concurrency {
                let index = next
                group.addTask { (index, await transform(tables[index])) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                try Task.checkCancellation()
                guard next < tables.count else { continue }
                let queued = next
                group.addTask { (queued, await transform(tables[queued])) }
                next += 1
            }
            return results.compactMap { $0 }
        }
    }

    /// What a whole-schema read produced, or nothing where the driver has no single-query form for
    /// it and the per-table read still has to run.
    /// A whole-schema answer plus the folded spellings of its own keys, indexed once. Every table
    /// that is missing from a sparse map asks for the folded fallback, so computing it per lookup
    /// made the fallback quadratic in the table count.
    private struct FoldedMap<Value: Sendable>: Sendable {
        let byName: [String: Value]
        let byFoldedName: [String: Value]

        init(_ map: [String: Value]) {
            byName = map
            var folded: [String: Value] = [:]
            var collided: Set<String> = []
            for (key, value) in map {
                let name = key.lowercased()
                guard !collided.contains(name) else { continue }
                if folded.updateValue(value, forKey: name) != nil {
                    folded.removeValue(forKey: name)
                    collided.insert(name)
                }
            }
            byFoldedName = folded
        }
    }

    private struct BulkMetadata: Sendable {
        var columns: FoldedMap<[PluginColumnInfo]>?
        var indexes: FoldedMap<[PluginIndexInfo]>?
        var foreignKeys: FoldedMap<[PluginForeignKeyInfo]>?
        var tableMetadata: FoldedMap<PluginTableMetadata>?

        /// The folded spellings that name exactly one table in this scope. A folded fallback is
        /// only safe for those.
        private var unambiguousFolded: Set<String> = []

        init() {}

        /// A whole-schema query that fails takes nothing with it: the read falls back to the
        /// per-table form, which reports a failure against the one table it belongs to rather than
        /// losing the comparison. That is the same rule the per-table read already followed.
        init(
            schema: String?,
            profile: TableReadProfile,
            tables: [PluginTableInfo],
            plugin: any PluginDatabaseDriver
        ) async {
            var counts: [String: Int] = [:]
            for table in tables {
                counts[table.name.lowercased(), default: 0] += 1
            }
            unambiguousFolded = Set(counts.filter { $0.value == 1 }.keys)

            if plugin.providesBulkColumnFetch {
                columns = (try? await plugin.fetchAllColumns(schema: schema)).map(FoldedMap.init)
            }
            if profile.wantsIndexes, plugin.providesBulkIndexFetch {
                indexes = (try? await plugin.fetchAllIndexes(schema: schema)).map(FoldedMap.init)
            }
            if profile.wantsForeignKeys, plugin.providesBulkForeignKeyFetch {
                foreignKeys = (try? await plugin.fetchAllForeignKeys(schema: schema)).map(FoldedMap.init)
            }
            if profile.wantsTableMetadata, plugin.providesBulkTableMetadataFetch {
                tableMetadata = (try? await plugin.fetchAllTableMetadata(schema: schema)).map(FoldedMap.init)
            }
        }

        /// True when nothing is left for the per-table path, so the fan-out over it is not worth
        /// starting.
        func answersEveryRead(for profile: TableReadProfile) -> Bool {
            guard columns != nil else { return false }
            if profile.wantsIndexes, indexes == nil { return false }
            if profile.wantsForeignKeys, foreignKeys == nil { return false }
            if profile.wantsTableMetadata, tableMetadata == nil { return false }
            return true
        }

        /// Engines disagree on identifier folding, so a name that was stored one way and listed
        /// another still has to find its entry.
        ///
        /// The folded fallback is refused where two tables in this scope fold to the same
        /// spelling. The index and foreign key maps are sparse, so a table with none has no exact
        /// entry, and PostgreSQL allows `"Foo"` beside `"foo"`: a folded match there handed one
        /// table's indexes to the other, and a DROP INDEX generated from that names the index
        /// alone, so it would have dropped the real one.
        func lookup<Value>(_ map: FoldedMap<Value>?, _ name: String) -> Value? {
            guard let map else { return nil }
            if let exact = map.byName[name] { return exact }
            let folded = name.lowercased()
            guard unambiguousFolded.contains(folded) else { return nil }
            return map.byFoldedName[folded]
        }
    }

    nonisolated private static func read(
        table: PluginTableInfo,
        schema: String?,
        profile: TableReadProfile,
        bulk: BulkMetadata,
        using plugin: any PluginDatabaseDriver
    ) async -> TableStructureRead {
        do {
            let columns = try await columns(of: table, schema: schema, bulk: bulk, using: plugin)
            let indexes = await indexes(of: table, schema: schema, profile: profile, bulk: bulk, using: plugin)
            let foreignKeys = await foreignKeys(
                of: table, schema: schema, profile: profile, bulk: bulk, using: plugin
            )
            let metadata = await metadata(of: table, schema: schema, profile: profile, bulk: bulk, using: plugin)
            return TableStructureRead(
                table: table, columns: columns, indexes: indexes,
                foreignKeys: foreignKeys, metadata: metadata, failure: nil
            )
        } catch {
            Self.logger.warning(
                "Structure read failed for \(table.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return TableStructureRead(
                table: table, columns: [], indexes: [], foreignKeys: [],
                metadata: nil, failure: error.localizedDescription
            )
        }
    }

    /// A table with no columns is not a real answer, so a name missing from the whole-schema list
    /// is read on its own. That keeps the per-table failure reporting, which an absent dictionary
    /// entry cannot express.
    nonisolated private static func columns(
        of table: PluginTableInfo,
        schema: String?,
        bulk: BulkMetadata,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [PluginColumnInfo] {
        if let columns = bulk.lookup(bulk.columns, table.name), !columns.isEmpty { return columns }
        return try await plugin.fetchColumns(table: table.name, schema: schema)
    }

    /// An empty index list is a real answer, unlike an empty column list, so a table absent from a
    /// whole-schema read has no indexes rather than needing a read of its own.
    nonisolated private static func indexes(
        of table: PluginTableInfo,
        schema: String?,
        profile: TableReadProfile,
        bulk: BulkMetadata,
        using plugin: any PluginDatabaseDriver
    ) async -> [PluginIndexInfo] {
        guard profile.wantsIndexes else { return [] }
        guard bulk.indexes == nil else { return bulk.lookup(bulk.indexes, table.name) ?? [] }
        return (try? await plugin.fetchIndexes(table: table.name, schema: schema)) ?? []
    }

    nonisolated private static func foreignKeys(
        of table: PluginTableInfo,
        schema: String?,
        profile: TableReadProfile,
        bulk: BulkMetadata,
        using plugin: any PluginDatabaseDriver
    ) async -> [PluginForeignKeyInfo] {
        guard profile.wantsForeignKeys else { return [] }
        guard bulk.foreignKeys == nil else { return bulk.lookup(bulk.foreignKeys, table.name) ?? [] }
        return (try? await plugin.fetchForeignKeys(table: table.name, schema: schema)) ?? []
    }

    nonisolated private static func metadata(
        of table: PluginTableInfo,
        schema: String?,
        profile: TableReadProfile,
        bulk: BulkMetadata,
        using plugin: any PluginDatabaseDriver
    ) async -> PluginTableMetadata? {
        guard profile.wantsTableMetadata else { return nil }
        guard bulk.tableMetadata == nil else { return bulk.lookup(bulk.tableMetadata, table.name) }
        return try? await plugin.fetchTableMetadata(table: table.name, schema: schema)
    }

    nonisolated internal static func pluginDriver(from driver: DatabaseDriver) -> (any PluginDatabaseDriver)? {
        (driver as? PluginDriverAdapter)?.schemaPluginDriver
    }
}

/// Which of the four per-table reads a caller actually looks at.
internal struct TableReadProfile: Sendable {
    internal let wantsIndexes: Bool
    internal let wantsForeignKeys: Bool
    internal let wantsTableMetadata: Bool

    internal static let structure = TableReadProfile(
        wantsIndexes: true, wantsForeignKeys: true, wantsTableMetadata: true
    )

    /// A data comparison pairs tables by name, reads the columns they share and walks their rows.
    /// It reads foreign keys to order the statements it writes, and it never looks at an index or
    /// at a storage engine.
    internal static let data = TableReadProfile(
        wantsIndexes: false, wantsForeignKeys: true, wantsTableMetadata: false
    )
}
