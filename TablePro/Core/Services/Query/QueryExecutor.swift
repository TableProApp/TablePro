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
    /// Columns the app must never write, whether the server computes the value from an expression
    /// or allocates it from an identity sequence the column cannot override. A `GENERATED ALWAYS
    /// AS IDENTITY` column belongs here for the same reason a stored generated column does: the
    /// engine rejects both an explicit INSERT value and an UPDATE of one.
    let generatedColumns: Set<String>
    let columnIdentity: [String: IdentityKind]
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

    // MARK: - Public orchestrators

    /// The driver is supplied by the caller, which resolved it from the tab's scope.
    /// Looking it up here would tie every query to whichever database the connection
    /// happens to be on.
    func executeQuery(
        driver: DatabaseDriver,
        sql: String,
        parameters: [Any?]? = nil,
        rowCap: Int?
    ) async throws -> QueryFetchResult {
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

    /// Bounding a fetch abandons the rest of it, which for some drivers cancels the statement on the
    /// server, so it is only ever offered a cap that `resolveRowCap` produced. That gate excludes
    /// writes and DDL; a caller computing its own cap (the MCP bridge caps a write that RETURNs)
    /// must not route here.
    nonisolated static func fetchBoundedQueryData(
        driver: DatabaseDriver,
        sql: String,
        rowCap: Int?
    ) async throws -> QueryFetchResult? {
        guard let rowCap, rowCap > 0 else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        guard let result = try await driver.executeBoundedQuery(query: sql, rowCap: rowCap) else {
            return nil
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        queryExecutorLog.info(
            "[executeBoundedQuery] rows=\(result.rows.count) truncated=\(result.isTruncated) totalTime=\(String(format: "%.3f", elapsed))s"
        )
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

    nonisolated static func fetchQueryData(
        driver: DatabaseDriver,
        sql: String,
        rowCap: Int?
    ) async throws -> QueryFetchResult {
        if let bounded = try await fetchBoundedQueryData(driver: driver, sql: sql, rowCap: rowCap) {
            return bounded
        }
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

    static func fetchTableSchema(scope: DatabaseScope, tableName: String) async throws -> FetchedTableSchema {
        queryExecutorLog.info(
            "[fk] schema fetch start table=\(tableName, privacy: .public) db=\(scope.database, privacy: .public) schema=\(scope.schema ?? "default", privacy: .public)"
        )
        let (columns, approximateRowCount) = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope
        ) { driver in
            let columns = try await driver.fetchColumns(table: tableName)
            let approximateRowCount = try? await driver.fetchApproximateRowCount(table: tableName)
            return (columns, approximateRowCount)
        }
        let foreignKeys = await fetchForeignKeys(scope: scope, tableName: tableName)
        queryExecutorLog.info(
            "[fk] schema fetch done table=\(tableName, privacy: .public) columns=\(columns.count) fks=\(foreignKeys.map { String($0.count) } ?? "failed", privacy: .public)"
        )
        return FetchedTableSchema(columns: columns, foreignKeys: foreignKeys, approximateRowCount: approximateRowCount)
    }

    private static func fetchForeignKeys(scope: DatabaseScope, tableName: String) async -> [ForeignKeyInfo]? {
        do {
            return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
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
        var identity: [String: IdentityKind] = [:]
        for col in schema.columns {
            defaults[col.name] = col.defaultValue
            nullable[col.name] = col.isNullable
            identity[col.name] = col.identityKind
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
            } else if let values = EnumValueParser.parseMySQLEnumOrSet(from: col.dataType), !values.isEmpty {
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
            generatedColumns: Set(
                schema.columns
                    .filter { $0.isGenerated || $0.identityKind == .always }
                    .map(\.name)
            ),
            columnIdentity: identity,
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
            generatedColumns: [],
            columnIdentity: [:],
            approximateRowCount: nil,
            columnEnumValues: [:],
            columnComments: [:]
        )
    }

    // MARK: - Row cap policy

    static func resolveRowCap(sql: String, tabType: TabType, databaseType: DatabaseType) -> Int? {
        let dataGridSettings = AppSettingsManager.shared.dataGrid
        guard dataGridSettings.truncateQueryResults,
              qualifiesForRowCap(sql: sql, tabType: tabType, databaseType: databaseType)
        else {
            return nil
        }
        let cap = dataGridSettings.validatedQueryResultRowCap
        return cap > 0 ? cap : nil
    }

    private static let rowProducingKeywords: Set<String> = ["SELECT", "WITH", "TABLE", "VALUES"]

    static func qualifiesForRowCap(sql: String, tabType: TabType, databaseType: DatabaseType) -> Bool {
        guard tabType == .query else { return false }
        let keyword = QueryClassifier.leadingKeyword(of: sql)
        return rowProducingKeywords.contains(keyword)
            && !QueryClassifier.isWriteQuery(sql, databaseType: databaseType)
            && !isDDLStatement(sql)
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
