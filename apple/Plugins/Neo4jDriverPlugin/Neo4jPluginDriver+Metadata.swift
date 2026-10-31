import Foundation
import os
import TableProNeo4jCore
import TableProPluginKit

extension Neo4jPluginDriver {
    static let tableType = "external table"

    func fetchDatabases() async throws -> [String] {
        do {
            let statement = try await run(
                "SHOW DATABASES YIELD name RETURN DISTINCT name ORDER BY name",
                database: "system"
            )
            let names = statement.records.compactMap { $0.first?.stringValue }
            if !names.isEmpty { return names }
        } catch let error as Neo4jError where !error.isAuthenticationFailure {
            Self.logger.info("SHOW DATABASES failed, listing the current database only")
        }
        let current = currentDatabase
        return current.isEmpty ? [] : [current]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchSchemas() async throws -> [String] {
        Neo4jEntityKind.allCases.map(\.schemaName)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) else { return [] }
        return try await tables(of: kind)
    }

    func fetchTablesInAllSchemas() async throws -> [PluginTableInfo]? {
        var tables: [PluginTableInfo] = []
        for kind in Neo4jEntityKind.allCases {
            tables += try await self.tables(of: kind)
        }
        return tables
    }

    private func tables(of kind: Neo4jEntityKind) async throws -> [PluginTableInfo] {
        let query = switch kind {
        case .node: "CALL db.labels() YIELD label RETURN label ORDER BY label"
        case .relationship: "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType ORDER BY relationshipType"
        }
        return try await run(query).records.compactMap { record in
            record.first?.stringValue.map {
                PluginTableInfo(name: $0, type: Self.tableType, schema: kind.schemaName)
            }
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        let sample = try await run(Neo4jCypher.propertySampleQuery(kind: kind, name: table))
        let properties = sample.records.compactMap { record -> (String, String)? in
            guard let key = record.first?.stringValue else { return nil }
            let type = record.count > 1 ? Neo4jValueText.typeName(record[1]) : "ANY"
            return (key, type)
        }
        rememberProperties(properties.map(\.0), kind: kind, name: table)

        let fixed = Neo4jCypher.fixedColumns(for: kind).map { name in
            PluginColumnInfo(
                name: name,
                dataType: name == Neo4jCypher.labelsColumn ? "LIST" : "STRING",
                isNullable: false,
                isPrimaryKey: name == Neo4jCypher.idColumn
            )
        }
        return fixed + properties.map { PluginColumnInfo(name: $0.0, dataType: $0.1, isNullable: true) }
    }

    /// Bolt 5 servers name an index's constraint in `owningConstraint`; 4.4 has only `uniqueness`.
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        let unique = usesElementId ? "owningConstraint IS NOT NULL" : "uniqueness = 'UNIQUE'"
        let query = """
        SHOW INDEXES YIELD *
        WHERE $name IN labelsOrTypes AND entityType = $entityType
        RETURN name, type, properties, \(unique) AS isUnique
        """
        let statement: Statement
        do {
            statement = try await run(query, parameters: ["name": .string(table), "entityType": .string(Self.entityType(kind))])
        } catch {
            Self.logger.info("SHOW INDEXES failed: \(error.localizedDescription, privacy: .private)")
            return []
        }
        return statement.records.compactMap { record in
            guard record.count == 4, let name = record[0].stringValue else { return nil }
            return PluginIndexInfo(
                name: name,
                columns: record[2].listValue?.compactMap(\.stringValue) ?? [],
                isUnique: record[3].boolValue ?? false,
                isPrimary: false,
                type: record[1].stringValue ?? ""
            )
        }
    }

    private static func entityType(_ kind: Neo4jEntityKind) -> String {
        switch kind {
        case .node: "NODE"
        case .relationship: "RELATIONSHIP"
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await rowCount(table: table, schema: schema, queryFilters: [], logicMode: "and")
    }

    func fetchFilteredRowCount(table: String, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        try await rowCount(table: table, schema: nil, queryFilters: queryFilters, logicMode: logicMode)
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        try await rowCount(table: table, schema: schema, queryFilters: queryFilters, logicMode: logicMode)
    }

    private func rowCount(table: String, schema: String?, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        let query = try Neo4jCypher.countQuery(
            kind: kind,
            name: table,
            filters: Self.neo4jFilters(queryFilters),
            matchesAll: logicMode.lowercased() != "or",
            usesElementId: usesElementId
        )
        return try await run(query).records.first?.first?.intValue.map(Int.init)
    }

    static func neo4jFilters(_ queryFilters: [PluginQueryFilter]) -> [Neo4jFilter] {
        queryFilters.map {
            Neo4jFilter(
                column: $0.column,
                op: $0.op,
                value: $0.value,
                secondValue: $0.secondValue,
                isCaseSensitive: $0.isCaseSensitive
            )
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        let query = """
        SHOW CONSTRAINTS YIELD labelsOrTypes, createStatement
        WHERE $name IN labelsOrTypes
        RETURN createStatement
        """
        let statements = (try? await run(query, parameters: ["name": .string(table)]))?
            .records.compactMap { $0.first?.stringValue } ?? []
        let pattern = Neo4jCypher.pattern(for: kind, name: table) + " RETURN n LIMIT 25;"
        return (statements.map { $0 + ";" } + [pattern]).joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw Neo4jError.server(code: "", message: String(localized: "Neo4j has no views."))
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "Neo4j")
    }

    // MARK: - Browsing

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table,
            schema: schema,
            queryFilters: [],
            logicMode: "and",
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset,
            columnKinds: [:]
        )
    }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table, schema: nil, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        let sort = sortColumns.compactMap { sort -> (column: String, ascending: Bool)? in
            guard columns.indices.contains(sort.columnIndex) else { return nil }
            return (columns[sort.columnIndex], sort.ascending)
        }
        return try? Neo4jCypher.browseQuery(
            kind: kind,
            name: table,
            filters: Self.neo4jFilters(queryFilters),
            matchesAll: logicMode.lowercased() != "or",
            sort: sort,
            limit: limit,
            offset: offset,
            usesElementId: usesElementId
        )
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        return try? Neo4jCypher.browseQuery(
            kind: kind, name: table, limit: Int(Int32.max), offset: 0, usesElementId: usesElementId
        )
    }
}
