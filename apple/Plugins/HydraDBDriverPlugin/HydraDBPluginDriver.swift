import Foundation
import TableProNeo4jCore
import TableProPluginKit

final class HydraDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private static let refusalQuery = "// TablePro HydraDB: unsupported filter or sort"
    private let driver: Neo4jPluginDriver

    init(config: DriverConnectionConfig) {
        driver = Neo4jPluginDriver(
            config: config, userAgent: "TablePro/\(HydraDBPlugin.pluginVersion)", discoversEntityProperties: true
        )
    }

    var capabilities: PluginCapabilities { driver.capabilities }
    var supportsTransactions: Bool { false }
    var supportsSchemas: Bool { true }
    var currentSchema: String? { driver.currentSchema }
    var currentDatabase: String? { driver.currentDatabase }
    var serverVersion: String? { driver.serverVersion }
    var parameterStyle: ParameterStyle { .dollar }

    func connect() async throws {
        try await driver.connect()
        if driver.currentDatabase.isEmpty { try await driver.switchDatabase(to: "default") }
    }
    func disconnect() { driver.disconnect() }
    func ping() async throws { try await driver.ping() }
    func cancelQuery() throws { try driver.cancelQuery() }
    func applyQueryTimeout(_ seconds: Int) async throws { try await driver.applyQueryTimeout(seconds) }
    func switchSchema(to schema: String) async throws { try await driver.switchSchema(to: schema) }
    func quoteIdentifier(_ name: String) -> String { driver.quoteIdentifier(name) }

    func execute(query: String) async throws -> PluginQueryResult {
        try validate(query)
        return try await driver.execute(query: query)
    }
    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        try validate(query)
        return try await driver.execute(query: query, context: context)
    }
    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try validate(query)
        return try await driver.executeParameterized(query: query, parameters: parameters)
    }
    func executeParameterized(
        query: String, parameters: [PluginCellValue], context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        try validate(query)
        return try await driver.executeParameterized(query: query, parameters: parameters, context: context)
    }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        try validate(query)
        return try await driver.executeUserQuery(query: query, rowCap: rowCap, parameters: parameters)
    }
    func executeUserQuery(
        query: String, rowCap: Int?, parameters: [PluginCellValue]?, context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        try validate(query)
        return try await driver.executeUserQuery(query: query, rowCap: rowCap, parameters: parameters, context: context)
    }
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        streamRows(query: query, context: PluginStatementContext())
    }
    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        do {
            try validate(query)
            return driver.streamRows(query: query, context: context)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func fetchDatabases() async throws -> [String] { [driver.currentDatabase.isEmpty ? "default" : driver.currentDatabase] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
    func fetchSchemas() async throws -> [String] { try await driver.fetchSchemas() }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { try await driver.fetchTables(schema: schema) }
    func fetchTablesInAllSchemas() async throws -> [PluginTableInfo]? { try await driver.fetchTablesInAllSchemas() }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        guard Neo4jCypher.isQuotable(table) else { throw Neo4jCypherError.unquotableName(table) }
        // HydraDB exposes entity properties, not Neo4j's keys/UNWIND metadata functions. Sparse properties
        // outside this bounded sample remain undiscovered, as with Neo4j's 1,000-entity sample.
        let sample = try await driver.run(Neo4jCypher.pattern(for: kind, name: table) + " RETURN n LIMIT 1000")
        let result = Neo4jResultTable.entities(kind: kind, records: sample.records, knownProperties: [])
        let fixed = Set(Neo4jCypher.fixedColumns(for: kind))
        driver.rememberProperties(result.columns.filter { !fixed.contains($0) }, kind: kind, name: table)
        return zip(result.columns, result.typeNames).map { name, type in
            PluginColumnInfo(
                name: name, dataType: type, isNullable: !fixed.contains(name),
                isPrimaryKey: name == Neo4jCypher.idColumn
            )
        }
    }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        throw unsupported(String(localized: "HydraDB does not expose index metadata over Bolt."))
    }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        throw unsupported(String(localized: "HydraDB does not expose schema DDL over Bolt."))
    }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw unsupported(String(localized: "HydraDB does not expose views over Bolt."))
    }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "HydraDB")
    }

    func buildBrowseQuery(
        table: String, schema: String?, sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String], limit: Int, offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: schema, queryFilters: [], logicMode: "and", sortColumns: sortColumns,
            columns: columns, limit: limit, offset: offset, columnKinds: [:]
        )
    }
    func buildBrowseQuery(
        table: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int
    ) -> String? {
        buildBrowseQuery(table: table, schema: nil, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset)
    }
    func buildFilteredQuery(
        table: String, schema: String?, queryFilters: [PluginQueryFilter], logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        do {
            let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
            let sort = try sortColumns.map { item -> (column: String, ascending: Bool) in
                guard columns.indices.contains(item.columnIndex) else { throw unsupported(String(localized: "Invalid sort column.")) }
                let column = columns[item.columnIndex]
                guard ![Neo4jCypher.startColumn, Neo4jCypher.endColumn, Neo4jCypher.labelsColumn].contains(column) else {
                    throw unsupported(String(localized: "HydraDB cannot sort this graph identity column."))
                }
                return (column, item.ascending)
            }
            var query = try Neo4jCypher.browseQuery(
                kind: kind, name: table, sort: sort, limit: limit, offset: offset, usesElementId: true
            )
            let predicate = try filterClause(queryFilters, logicMode: logicMode, columnKinds: columnKinds)
            if !predicate.isEmpty {
                let pattern = Neo4jCypher.pattern(for: kind, name: table)
                guard let match = query.range(of: pattern, options: .literal) else {
                    throw unsupported(String(localized: "Could not build the HydraDB filter."))
                }
                query.insert(contentsOf: "\n" + predicate, at: match.upperBound)
            }
            return query
        } catch {
            // Retain a local refusal token so the host cannot replace a rejected filter with generic SQL.
            return Self.refusalQuery
        }
    }
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await fetchExactRowCount(table: table, schema: schema, queryFilters: [], logicMode: "and")
    }
    func fetchFilteredRowCount(table: String, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        try await fetchExactRowCount(table: table, schema: currentSchema, queryFilters: queryFilters, logicMode: logicMode)
    }
    func fetchExactRowCount(
        table: String, schema: String?, queryFilters: [PluginQueryFilter], logicMode: String
    ) async throws -> Int? {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        guard Neo4jCypher.isQuotable(table) else { throw Neo4jCypherError.unquotableName(table) }
        let columns = queryFilters.isEmpty ? [] : try await fetchColumns(table: table, schema: schema)
        let kinds = Dictionary(columns.map { column in
            let kind: PluginColumnKind = switch column.dataType {
            case "STRING": .text
            case "INTEGER": .integer
            case "FLOAT": .decimal
            case "BOOLEAN": .boolean
            default: .other
            }
            return (column.name, kind)
        }, uniquingKeysWith: { first, _ in first })
        let predicate = try filterClause(queryFilters, logicMode: logicMode, columnKinds: kinds)
        let query = Neo4jCypher.pattern(for: kind, name: table) + "\n" + predicate + "\nRETURN count(*) AS count"
        return try await driver.run(query).records.first?.first?.intValue.map(Int.init)
    }
    func defaultExportQuery(table: String, schema: String?) -> String? {
        let kind = Neo4jEntityKind(schemaName: schema ?? currentSchema) ?? .node
        return try? Neo4jCypher.exportQuery(kind: kind, name: table)
    }
    func defaultExportQuery(table: String) -> String? { defaultExportQuery(table: table, schema: nil) }

    private func filterClause(
        _ filters: [PluginQueryFilter], logicMode: String, columnKinds: [String: PluginColumnKind] = [:]
    ) throws -> String {
        let clauses = try filters.map { filter -> String in
            let op = filter.op.uppercased()
            let numericKind = [PluginColumnKind.integer, .decimal, .boolean].contains(columnKinds[filter.column] ?? .other)
            guard filter.isCaseSensitive || numericKind, filter.elementScope == nil, filter.secondValue == nil,
                  ["=", "<>", "<", "<=", ">", ">=", "STARTS WITH"].contains(op),
                  ![Neo4jCypher.rawFilterColumn, Neo4jCypher.idColumn, Neo4jCypher.labelsColumn,
                    Neo4jCypher.startColumn, Neo4jCypher.endColumn].contains(filter.column) else {
                throw unsupported(String(localized: "This filter is not supported by HydraDB."))
            }
            guard Neo4jCypher.isQuotable(filter.column) else { throw Neo4jCypherError.unquotableName(filter.column) }
            let value: String
            if op != "STARTS WITH", columnKinds[filter.column] != .text,
               let integer = Int64(filter.value), String(integer) == filter.value {
                value = filter.value
            } else if op != "STARTS WITH", columnKinds[filter.column] != .text,
                      filter.value.contains(".") || filter.value.contains("e") || filter.value.contains("E"),
                      PluginNumericLiteral.isValid(filter.value), let number = Double(filter.value), number.isFinite {
                value = filter.value
            } else if op != "STARTS WITH", columnKinds[filter.column] != .text,
                      ["true", "false"].contains(filter.value.lowercased()) {
                value = filter.value.lowercased()
            } else {
                value = Neo4jCypher.literal(filter.value)
            }
            return "n.\(Neo4jCypher.quote(filter.column)) \(op) \(value)"
        }
        guard !clauses.isEmpty else { return "" }
        let separator = logicMode.lowercased() == "or" ? " OR " : " AND "
        return "WHERE " + clauses.map { "(\($0))" }.joined(separator: separator)
    }
    private func validate(_ query: String) throws {
        if query.trimmingCharacters(in: .whitespacesAndNewlines) == Self.refusalQuery {
            throw unsupported(String(localized: "This filter or sort is not supported by HydraDB."))
        }
    }

    func beginTransaction() async throws {
        throw unsupported(String(localized: "HydraDB transactions are not supported by this driver."))
    }
    func commitTransaction() async throws {
        throw unsupported(String(localized: "HydraDB transactions are not supported by this driver."))
    }
    func rollbackTransaction() async throws {
        throw unsupported(String(localized: "HydraDB transactions are not supported by this driver."))
    }

    private func unsupported(_ message: String) -> Neo4jError { .server(code: "TablePro.HydraDB.Unsupported", message: message) }
}
