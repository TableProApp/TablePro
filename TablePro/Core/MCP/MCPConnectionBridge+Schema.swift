import Foundation
import os
import TableProPluginKit

extension MCPConnectionBridge {
    static let rowCountFanOutLimit = 200

    func listTables(scope: DatabaseScope, includeRowCounts: Bool) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)

        let tables = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchTables(schema: scope.schema)
        }
        let ordered = Self.sortedTables(tables)

        guard includeRowCounts, ordered.count <= Self.rowCountFanOutLimit else {
            return .object([
                "tables": .array(ordered.map { Self.encode(table: $0, rowCount: $0.rowCount) }),
                "database": .string(scope.database),
                "schema": scope.schema.map(JsonValue.string) ?? JsonValue.null,
                "row_counts_included": .bool(false)
            ])
        }

        let names = ordered.map(\.name)
        let counts = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope,
            workload: .bulk
        ) { driver in
            var resolved: [String: Int] = [:]
            for name in names {
                if let count = try? await driver.fetchApproximateRowCount(table: name) {
                    resolved[name] = count
                }
            }
            return resolved
        }

        return .object([
            "tables": .array(ordered.map { Self.encode(table: $0, rowCount: counts[$0.name] ?? $0.rowCount) }),
            "database": .string(scope.database),
            "schema": scope.schema.map(JsonValue.string) ?? JsonValue.null,
            "row_counts_included": .bool(true),
            "row_counts_are_approximate": .bool(true)
        ])
    }

    func describeTable(scope: DatabaseScope, table: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schema = scope.schema

        return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            let columns = try await driver.fetchColumns(table: table, schema: schema)
            let indexes = try await driver.fetchIndexes(table: table)
            let foreignKeys = try await driver.fetchForeignKeys(table: table)
            let approximateRowCount = (try? await driver.fetchApproximateRowCount(table: table)) ?? nil
            let ddl = try? await driver.fetchTableDDL(table: table)

            var result: [String: JsonValue] = [
                "table": .string(table),
                "database": .string(scope.database),
                "schema": schema.map { .string($0) } ?? .null,
                "columns": .array(columns.map(MCPConnectionBridge.encode(column:))),
                "indexes": .array(indexes.map(MCPConnectionBridge.encode(index:))),
                "foreign_keys": .array(foreignKeys.map(MCPConnectionBridge.encode(foreignKey:)))
            ]
            if let ddl {
                result["ddl"] = .string(ddl)
            }
            if let approximateRowCount {
                result["approximate_row_count"] = .int(approximateRowCount)
            }
            return .object(result)
        }
    }

    func listDatabases(connectionId: UUID) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        let databases = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.fetchDatabases()
        }
        return .object(["databases": .array(databases.sorted().map { .string($0) })])
    }

    func listSchemas(scope: DatabaseScope) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schemas = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchSchemas()
        }
        return .object([
            "schemas": .array(schemas.sorted().map { .string($0) }),
            "database": .string(scope.database)
        ])
    }

    func getTableDDL(scope: DatabaseScope, table: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let ddl = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchTableDDL(table: table)
        }
        return .object([
            "table": .string(table),
            "schema": scope.schema.map(JsonValue.string) ?? JsonValue.null,
            "ddl": .string(ddl)
        ])
    }

    func listIndexes(scope: DatabaseScope, table: String?) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schema = scope.schema
        let payload = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope,
            workload: table == nil ? .bulk : .interactive
        ) { driver in
            let targets: [String]
            if let table {
                targets = [table]
            } else {
                targets = try await driver.fetchTables(schema: schema).map(\.name).sorted()
            }
            var entries: [JsonValue] = []
            for target in targets {
                let indexes = (try? await driver.fetchIndexes(table: target)) ?? []
                guard !indexes.isEmpty else { continue }
                entries.append(.object([
                    "table": .string(target),
                    "indexes": .array(indexes.map(MCPConnectionBridge.encode(index:)))
                ]))
            }
            return entries
        }
        return .object([
            "database": .string(scope.database),
            "schema": scope.schema.map(JsonValue.string) ?? JsonValue.null,
            "tables": .array(payload)
        ])
    }

    func listForeignKeys(scope: DatabaseScope, table: String?) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schema = scope.schema
        let entries = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope,
            workload: table == nil ? .bulk : .interactive
        ) { driver in
            if let table {
                let keys = try await driver.fetchForeignKeys(table: table)
                return [table: keys]
            }
            let names = try await driver.fetchTables(schema: schema).map(\.name)
            return try await driver.fetchForeignKeys(forTables: names)
        }

        let payload: [JsonValue] = entries.keys.sorted().compactMap { key in
            guard let keys = entries[key], !keys.isEmpty else { return nil }
            return .object([
                "table": .string(key),
                "foreign_keys": .array(keys.map(MCPConnectionBridge.encode(foreignKey:)))
            ])
        }
        return .object([
            "database": .string(scope.database),
            "schema": scope.schema.map(JsonValue.string) ?? JsonValue.null,
            "tables": .array(payload)
        ])
    }

    func listTriggers(scope: DatabaseScope, table: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let triggers = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchTriggers(table: table)
        }
        let payload = triggers
            .sorted { $0.name < $1.name }
            .map { trigger -> JsonValue in
                var fields: [String: JsonValue] = [
                    "name": .string(trigger.name),
                    "timing": .string(trigger.timing),
                    "event": .string(trigger.event),
                    "statement": .string(trigger.statement)
                ]
                if let enabled = trigger.enabled {
                    fields["is_enabled"] = .bool(enabled)
                }
                return .object(fields)
            }
        return .object(["table": .string(table), "triggers": .array(payload)])
    }

    func getViewDefinition(scope: DatabaseScope, view: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let definition = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchViewDefinition(view: view)
        }
        return .object([
            "view": .string(view),
            "schema": scope.schema.map(JsonValue.string) ?? JsonValue.null,
            "definition": .string(definition)
        ])
    }

    func listRoutines(scope: DatabaseScope, kind: String?) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schema = scope.schema
        let routines = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            var collected: [RoutineInfo] = []
            if kind == nil || kind == "procedure" {
                collected += try await driver.fetchProcedures(schema: schema)
            }
            if kind == nil || kind == "function" {
                collected += try await driver.fetchFunctions(schema: schema)
            }
            return collected
        }
        let payload = routines
            .sorted { $0.qualifiedName < $1.qualifiedName }
            .map { routine -> JsonValue in
                var fields: [String: JsonValue] = [
                    "name": .string(routine.name),
                    "kind": .string(routine.kind.rawValue),
                    "qualified_name": .string(routine.qualifiedName)
                ]
                if let schema = routine.schema {
                    fields["schema"] = .string(schema)
                }
                if let signature = routine.signature {
                    fields["signature"] = .string(signature)
                }
                return .object(fields)
            }
        return .object(["routines": .array(payload)])
    }

    func listPartitions(scope: DatabaseScope, table: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schema = scope.schema
        let partitions = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchPartitions(table: table, schema: schema)
        }
        return .object([
            "table": .string(table),
            "partitions": .array(Self.sortedTables(partitions).map { Self.encode(table: $0, rowCount: $0.rowCount) })
        ])
    }

    func tableMetadata(scope: DatabaseScope, table: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let metadata = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchTableMetadata(tableName: table)
        }
        var fields: [String: JsonValue] = ["table": .string(metadata.tableName)]
        if let value = metadata.dataSize { fields["data_size_bytes"] = .int(Int(value)) }
        if let value = metadata.indexSize { fields["index_size_bytes"] = .int(Int(value)) }
        if let value = metadata.totalSize { fields["total_size_bytes"] = .int(Int(value)) }
        if let value = metadata.avgRowLength { fields["average_row_length"] = .int(Int(value)) }
        if let value = metadata.rowCount { fields["row_count"] = .int(Int(value)) }
        if let value = metadata.comment { fields["comment"] = .string(value) }
        if let value = metadata.engine { fields["engine"] = .string(value) }
        if let value = metadata.collation { fields["collation"] = .string(value) }
        if let value = metadata.createTime { fields["created_at"] = .string(Self.iso8601.withLockUnchecked { $0.string(from: value) }) }
        if let value = metadata.updateTime { fields["updated_at"] = .string(Self.iso8601.withLockUnchecked { $0.string(from: value) }) }
        return .object(fields)
    }

    func databaseMetadata(connectionId: UUID, database: String?) async throws -> JsonValue {
        try await ensureConnected(connectionId)
        let scope = await MainActor.run { DatabaseManager.shared.browseScope(for: connectionId) }
        guard let scope else {
            throw MCPDataLayerError.notConnected(connectionId)
        }
        let metadata = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope,
            workload: .bulk
        ) { driver in
            if let database {
                return [try await driver.fetchDatabaseMetadata(database)]
            }
            return try await driver.fetchAllDatabaseMetadata()
        }
        let payload = metadata
            .sorted { $0.name < $1.name }
            .map { entry -> JsonValue in
                var fields: [String: JsonValue] = [
                    "name": .string(entry.name),
                    "is_system_database": .bool(entry.isSystemDatabase)
                ]
                if let count = entry.tableCount { fields["table_count"] = .int(count) }
                if let size = entry.sizeBytes { fields["size_bytes"] = .int(Int(size)) }
                return .object(fields)
            }
        return .object(["databases": .array(payload)])
    }

    static func sortedTables(_ tables: [TableInfo]) -> [TableInfo] {
        tables.sorted { lhs, rhs in
            let lhsSchema = lhs.schema ?? ""
            let rhsSchema = rhs.schema ?? ""
            if lhsSchema != rhsSchema { return lhsSchema < rhsSchema }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.type.rawValue < rhs.type.rawValue
        }
    }

    static func encode(table: TableInfo, rowCount: Int?) -> JsonValue {
        var fields: [String: JsonValue] = [
            "name": .string(table.name),
            "type": .string(table.type.rawValue)
        ]
        if let schema = table.schema, !schema.isEmpty {
            fields["schema"] = .string(schema)
        }
        if let comment = table.comment, !comment.isEmpty {
            fields["comment"] = .string(comment)
        }
        if let rowCount {
            fields["row_count"] = .int(rowCount)
        }
        return .object(fields)
    }

    static func encode(column: ColumnInfo) -> JsonValue {
        var fields: [String: JsonValue] = [
            "name": .string(column.name),
            "data_type": .string(column.dataType),
            "is_nullable": .bool(column.isNullable),
            "is_primary_key": .bool(column.isPrimaryKey),
            "is_generated": .bool(column.isGenerated)
        ]
        if let value = column.defaultValue { fields["default_value"] = .string(value) }
        if let value = column.extra, !value.isEmpty { fields["extra"] = .string(value) }
        if let value = column.comment, !value.isEmpty { fields["comment"] = .string(value) }
        if let values = column.allowedValues, !values.isEmpty {
            fields["allowed_values"] = .array(values.map { .string($0) })
        }
        return .object(fields)
    }

    static func encode(index: IndexInfo) -> JsonValue {
        var fields: [String: JsonValue] = [
            "name": .string(index.name),
            "columns": .array(index.columns.map { .string($0) }),
            "is_unique": .bool(index.isUnique),
            "is_primary": .bool(index.isPrimary),
            "type": .string(index.type)
        ]
        if let whereClause = index.whereClause, !whereClause.isEmpty {
            fields["where_clause"] = .string(whereClause)
        }
        return .object(fields)
    }

    static func encode(foreignKey: ForeignKeyInfo) -> JsonValue {
        var fields: [String: JsonValue] = [
            "name": .string(foreignKey.name),
            "column": .string(foreignKey.column),
            "referenced_table": .string(foreignKey.referencedTable),
            "referenced_column": .string(foreignKey.referencedColumn),
            "on_delete": .string(foreignKey.onDelete),
            "on_update": .string(foreignKey.onUpdate)
        ]
        if let schema = foreignKey.referencedSchema {
            fields["referenced_schema"] = .string(schema)
        }
        return .object(fields)
    }
}
