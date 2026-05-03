import Foundation
import os
import TableProPluginKit

private let queryExecutorLog = Logger(subsystem: "com.TablePro", category: "QueryExecutor")

struct QueryFetchResult {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[String?]]
    let executionTime: TimeInterval
    let rowsAffected: Int
    let statusMessage: String?
    let isTruncated: Bool
}

typealias SchemaResult = (columnInfo: [ColumnInfo], fkInfo: [ForeignKeyInfo], approximateRowCount: Int?)

struct ParsedSchemaMetadata {
    let columnDefaults: [String: String?]
    let columnForeignKeys: [String: ForeignKeyInfo]
    let columnNullable: [String: Bool]
    let primaryKeyColumns: [String]
    let approximateRowCount: Int?
    let columnEnumValues: [String: [String]]
}

struct QueryExecutionResult {
    let fetchResult: QueryFetchResult
    let schemaResult: SchemaResult?
    let parsedMetadata: ParsedSchemaMetadata?
}

@MainActor
final class QueryExecutor {
    let connection: DatabaseConnection
    var connectionId: UUID { connection.id }

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - Driver access

    private func resolveDriver() throws -> DatabaseDriver {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        return driver
    }

    // MARK: - Public orchestrators

    func executeQuery(
        sql: String,
        parameters: [Any?]? = nil,
        rowCap: Int?,
        tableName: String?,
        fetchSchemaForTable: Bool
    ) async throws -> QueryExecutionResult {
        let connId = connectionId

        var parallelSchemaTask: Task<SchemaResult, Error>?
        if fetchSchemaForTable, let tableName, !tableName.isEmpty {
            parallelSchemaTask = Task {
                guard let driver = DatabaseManager.shared.driver(for: connId) else {
                    throw DatabaseError.notConnected
                }
                async let cols = driver.fetchColumns(table: tableName)
                async let fks = driver.fetchForeignKeys(table: tableName)
                let result = try await (columnInfo: cols, fkInfo: fks)
                let approxCount = try? await driver.fetchApproximateRowCount(table: tableName)
                return (
                    columnInfo: result.columnInfo,
                    fkInfo: result.fkInfo,
                    approximateRowCount: approxCount
                )
            }
        }

        let driver = try resolveDriver()

        let fetchResult: QueryFetchResult
        do {
            if let parameters {
                fetchResult = try await Self.fetchQueryDataParameterized(
                    driver: driver,
                    sql: sql,
                    parameters: parameters,
                    rowCap: rowCap
                )
            } else {
                fetchResult = try await Self.fetchQueryData(
                    driver: driver,
                    sql: sql,
                    rowCap: rowCap
                )
            }
        } catch {
            parallelSchemaTask?.cancel()
            throw error
        }

        var schemaResult: SchemaResult?
        if fetchSchemaForTable, let tableName, !tableName.isEmpty {
            schemaResult = await Self.awaitSchemaResult(
                connectionId: connId,
                parallelTask: parallelSchemaTask,
                tableName: tableName
            )
        }

        let parsedMetadata = schemaResult.map { Self.parseSchemaMetadata($0) }

        return QueryExecutionResult(
            fetchResult: fetchResult,
            schemaResult: schemaResult,
            parsedMetadata: parsedMetadata
        )
    }

    // MARK: - Driver fetch (nonisolated, runs on background)

    nonisolated static func fetchQueryData(
        driver: DatabaseDriver,
        sql: String,
        rowCap: Int?
    ) async throws -> QueryFetchResult {
        let start = CFAbsoluteTimeGetCurrent()
        queryExecutorLog.info("[executeUserQuery] sql=\(sql.prefix(100), privacy: .public) rowCap=\(rowCap?.description ?? "nil")")
        let result = try await driver.executeUserQuery(query: sql, rowCap: rowCap, parameters: nil)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        queryExecutorLog.info("[executeUserQuery] rows=\(result.rows.count) truncated=\(result.isTruncated) driverTime=\(String(format: "%.3f", result.executionTime))s totalTime=\(String(format: "%.3f", elapsed))s")
        return QueryFetchResult(
            columns: result.columns,
            columnTypes: result.columnTypes,
            rows: result.rows,
            executionTime: result.executionTime,
            rowsAffected: result.rowsAffected,
            statusMessage: result.statusMessage,
            isTruncated: result.isTruncated
        )
    }

    nonisolated static func fetchQueryDataParameterized(
        driver: DatabaseDriver,
        sql: String,
        parameters: [Any?],
        rowCap: Int?
    ) async throws -> QueryFetchResult {
        let start = CFAbsoluteTimeGetCurrent()
        queryExecutorLog.info("[executeUserQueryParameterized] sql=\(sql.prefix(100), privacy: .public) rowCap=\(rowCap?.description ?? "nil") params=\(parameters.count)")
        let result = try await driver.executeUserQuery(query: sql, rowCap: rowCap, parameters: parameters)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        queryExecutorLog.info("[executeUserQueryParameterized] rows=\(result.rows.count) truncated=\(result.isTruncated) driverTime=\(String(format: "%.3f", result.executionTime))s totalTime=\(String(format: "%.3f", elapsed))s")
        return QueryFetchResult(
            columns: result.columns,
            columnTypes: result.columnTypes,
            rows: result.rows,
            executionTime: result.executionTime,
            rowsAffected: result.rowsAffected,
            statusMessage: result.statusMessage,
            isTruncated: result.isTruncated
        )
    }

    // MARK: - Schema await + parse

    static func awaitSchemaResult(
        connectionId: UUID,
        parallelTask: Task<SchemaResult, Error>?,
        tableName: String
    ) async -> SchemaResult? {
        if let parallelTask {
            return try? await parallelTask.value
        }
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return nil }
        do {
            async let cols = driver.fetchColumns(table: tableName)
            async let fks = driver.fetchForeignKeys(table: tableName)
            let (c, f) = try await (cols, fks)
            let approxCount = try? await driver.fetchApproximateRowCount(table: tableName)
            return (columnInfo: c, fkInfo: f, approximateRowCount: approxCount)
        } catch {
            queryExecutorLog.error("Phase 2 schema fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func parseSchemaMetadata(_ schema: SchemaResult) -> ParsedSchemaMetadata {
        var defaults: [String: String?] = [:]
        var fks: [String: ForeignKeyInfo] = [:]
        var nullable: [String: Bool] = [:]
        for col in schema.columnInfo {
            defaults[col.name] = col.defaultValue
            nullable[col.name] = col.isNullable
        }
        for fk in schema.fkInfo {
            fks[fk.column] = fk
        }
        var enumValues: [String: [String]] = [:]
        for col in schema.columnInfo {
            if let values = ColumnType.parseEnumValues(from: col.dataType) {
                enumValues[col.name] = values
            } else if let values = ColumnType.parseClickHouseEnumValues(from: col.dataType) {
                enumValues[col.name] = values
            }
        }
        return ParsedSchemaMetadata(
            columnDefaults: defaults,
            columnForeignKeys: fks,
            columnNullable: nullable,
            primaryKeyColumns: schema.columnInfo.filter { $0.isPrimaryKey }.map(\.name),
            approximateRowCount: schema.approximateRowCount,
            columnEnumValues: enumValues
        )
    }

    // MARK: - Row cap policy

    static func resolveRowCap(sql: String, tabType: TabType, databaseType: DatabaseType) -> Int? {
        let dataGridSettings = AppSettingsManager.shared.dataGrid
        let trimmedUpper = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isSelectQuery = trimmedUpper.hasPrefix("SELECT ") || trimmedUpper.hasPrefix("WITH ")
        let isWrite = QueryClassifier.isWriteQuery(sql, databaseType: databaseType)
        let isDDL = isDDLStatement(sql)

        guard tabType == .query, isSelectQuery, !isWrite, !isDDL,
              dataGridSettings.truncateQueryResults
        else {
            return nil
        }
        return dataGridSettings.validatedQueryResultRowCap
    }

    private static let ddlPrefixes: [String] = [
        "CREATE", "DROP", "ALTER", "TRUNCATE", "RENAME",
    ]

    static func isDDLStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ddlPrefixes.contains { trimmed.hasPrefix($0) }
    }

    // MARK: - Parameter detection

    static func detectAndReconcileParameters(
        sql: String,
        existing: [QueryParameter]
    ) -> [QueryParameter] {
        let detectedNames = SQLParameterExtractor.extractParameters(from: sql)
        guard !detectedNames.isEmpty else { return [] }

        let existingByName = Dictionary(
            existing.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return detectedNames.map { name in
            if let existing = existingByName[name] {
                return existing
            }
            return QueryParameter(name: name)
        }
    }
}
