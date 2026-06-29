import Foundation
import os
import TableProPluginKit

private let queryExecutorLog = Logger(subsystem: "com.TablePro", category: "QueryExecutor")

struct QueryFetchResult {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[PluginCellValue]]
    let executionTime: TimeInterval
    let rowsAffected: Int
    let statusMessage: String?
    let isTruncated: Bool
    let resultColumnMeta: [ResultColumnMeta]?
}

struct FetchedTableSchema {
    let columns: [ColumnInfo]
    let foreignKeys: [ForeignKeyInfo]?
    let approximateRowCount: Int?
}

struct ParsedSchemaMetadata {
    let columnDefaults: [String: String?]
    let columnForeignKeys: [String: ForeignKeyInfo]?
    let columnNullable: [String: Bool]
    let primaryKeyColumns: [String]
    let approximateRowCount: Int?
    let columnEnumValues: [String: [String]]
    let columnComments: [String: String]
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
        rowCap: Int?
    ) async throws -> QueryFetchResult {
        let driver = try resolveDriver()

        if let parameters {
            return try await Self.fetchQueryDataParameterized(
                driver: driver,
                sql: sql,
                parameters: parameters,
                rowCap: rowCap
            )
        }
        return try await Self.fetchQueryData(
            driver: driver,
            sql: sql,
            rowCap: rowCap
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
            isTruncated: result.isTruncated,
            resultColumnMeta: result.columnMeta
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
            isTruncated: result.isTruncated,
            resultColumnMeta: result.columnMeta
        )
    }

    // MARK: - Schema fetch + parse

    static func fetchTableSchema(connectionId: UUID, tableName: String) async throws -> FetchedTableSchema {
        let session = DatabaseManager.shared.session(for: connectionId)
        queryExecutorLog.info(
            "[fk] schema fetch start table=\(tableName, privacy: .public) db=\(session?.currentDatabase ?? "default", privacy: .public) schema=\(session?.currentSchema ?? "default", privacy: .public)"
        )
        let (columns, approximateRowCount) = try await DatabaseManager.shared.withMetadataDriver(
            connectionId: connectionId
        ) { driver in
            let columns = try await driver.fetchColumns(table: tableName)
            let approximateRowCount = try? await driver.fetchApproximateRowCount(table: tableName)
            return (columns, approximateRowCount)
        }
        let foreignKeys = await fetchForeignKeys(connectionId: connectionId, tableName: tableName)
        queryExecutorLog.info(
            "[fk] schema fetch done table=\(tableName, privacy: .public) columns=\(columns.count) fks=\(foreignKeys.map { String($0.count) } ?? "failed", privacy: .public)"
        )
        return FetchedTableSchema(columns: columns, foreignKeys: foreignKeys, approximateRowCount: approximateRowCount)
    }

    private static func fetchForeignKeys(connectionId: UUID, tableName: String) async -> [ForeignKeyInfo]? {
        do {
            return try await DatabaseManager.shared.withMetadataDriver(connectionId: connectionId) { driver in
                try await driver.fetchForeignKeys(table: tableName)
            }
        } catch {
            queryExecutorLog.error(
                "[fk] FK fetch failed for \(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func parseSchemaMetadata(_ schema: FetchedTableSchema) -> ParsedSchemaMetadata {
        var defaults: [String: String?] = [:]
        var nullable: [String: Bool] = [:]
        for col in schema.columns {
            defaults[col.name] = col.defaultValue
            nullable[col.name] = col.isNullable
        }
        var fks: [String: ForeignKeyInfo]?
        if let foreignKeys = schema.foreignKeys {
            var byColumn: [String: ForeignKeyInfo] = [:]
            for fk in foreignKeys {
                byColumn[fk.column] = fk
            }
            fks = byColumn
        }
        var enumValues: [String: [String]] = [:]
        var comments: [String: String] = [:]
        for col in schema.columns {
            if let values = col.allowedValues, !values.isEmpty {
                enumValues[col.name] = values
            }
            if let comment = col.comment?.nilIfEmpty {
                comments[col.name] = comment
            }
        }
        return ParsedSchemaMetadata(
            columnDefaults: defaults,
            columnForeignKeys: fks,
            columnNullable: nullable,
            primaryKeyColumns: schema.columns.filter { $0.isPrimaryKey }.map(\.name),
            approximateRowCount: schema.approximateRowCount,
            columnEnumValues: enumValues,
            columnComments: comments
        )
    }

    static func inlineMetadata(from meta: [ResultColumnMeta]?, columns: [String]) -> ParsedSchemaMetadata? {
        guard let meta, !meta.isEmpty, meta.count == columns.count else { return nil }
        var nullable: [String: Bool] = [:]
        var primaryKeys: [String] = []
        for (index, column) in columns.enumerated() {
            nullable[column] = meta[index].isNullable
            if meta[index].isPrimaryKey {
                primaryKeys.append(column)
            }
        }
        return ParsedSchemaMetadata(
            columnDefaults: [:],
            columnForeignKeys: nil,
            columnNullable: nullable,
            primaryKeyColumns: primaryKeys,
            approximateRowCount: nil,
            columnEnumValues: [:],
            columnComments: [:]
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
