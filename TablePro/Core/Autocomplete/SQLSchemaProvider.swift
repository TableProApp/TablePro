//
//  SQLSchemaProvider.swift
//  TablePro
//
//  Cached database schema provider for autocomplete
//

import Foundation
import os
import TableProPluginKit

/// Provides cached database schema information for autocomplete
actor SQLSchemaProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLSchemaProvider")
    // MARK: - Properties

    private var tables: [TableInfo] = []
    private var columnCache: [String: [ColumnInfo]] = [:]
    private var columnAccessOrder: [String] = []
    private let maxCachedTables = 50
    private var isLoading = false
    private var lastLoadError: Error?
    private var lastRetryAttempt: Date?
    private let retryCooldown: TimeInterval = 30

    // Store a weak driver reference to avoid retaining it after disconnect (MEM-9)
    private weak var cachedDriver: (any DatabaseDriver)?

    // Store connection info for reference
    private var connectionInfo: DatabaseConnection?

    // MARK: - Public API

    /// Load schema from the database (driver should already be connected)
    func loadSchema(using driver: DatabaseDriver, connection: DatabaseConnection? = nil) async {
        guard !isLoading else { return }

        // Store driver reference for later column fetching
        self.cachedDriver = driver
        self.connectionInfo = connection
        isLoading = true
        lastLoadError = nil

        do {
            tables = try await driver.fetchTables()
            isLoading = false
        } catch {
            lastLoadError = error
            isLoading = false
        }
    }

    /// Get all tables
    func getTables() -> [TableInfo] {
        tables
    }

    /// Get columns for a specific table (with LRU caching)
    func getColumns(for tableName: String) async -> [ColumnInfo] {
        let key = tableName.lowercased()

        if let cached = columnCache[key] {
            columnAccessOrder.removeAll { $0 == key }
            columnAccessOrder.append(key)
            return cached
        }

        guard let driver = cachedDriver else {
            return []
        }

        do {
            let columns = try await driver.fetchColumns(table: tableName)
            columnCache[key] = columns
            columnAccessOrder.append(key)
            evictIfNeeded()
            return columns
        } catch {
            Self.logger.debug("Column fetch failed for autocomplete: \(error.localizedDescription)")
            return []
        }
    }

    private func evictIfNeeded() {
        while columnAccessOrder.count > maxCachedTables {
            let evicted = columnAccessOrder.removeFirst()
            columnCache.removeValue(forKey: evicted)
        }
    }

    func retryLoadSchemaIfNeeded() async {
        guard lastLoadError != nil, tables.isEmpty, !isLoading else { return }
        guard let driver = cachedDriver else { return }
        if let last = lastRetryAttempt, Date().timeIntervalSince(last) < retryCooldown { return }
        lastRetryAttempt = Date()
        lastLoadError = nil
        await loadSchema(using: driver, connection: connectionInfo)
    }

    /// Check if schema is loaded
    func isSchemaLoaded() -> Bool {
        !tables.isEmpty
    }

    /// Check if currently loading
    func isCurrentlyLoading() -> Bool {
        isLoading
    }

    func updateTables(_ newTables: [TableInfo]) {
        tables = newTables
    }

    func resetForDatabase(_ database: String?, tables newTables: [TableInfo], driver: DatabaseDriver) {
        self.tables = newTables
        self.columnCache.removeAll()
        self.columnAccessOrder.removeAll()
        self.cachedDriver = driver
        self.isLoading = false
        self.lastLoadError = nil
    }

    /// Find table name from alias
    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) -> String? {
        let lowerName = aliasOrName.lowercased()

        // First check if it's an alias
        for ref in references {
            if ref.alias?.lowercased() == lowerName {
                return ref.tableName
            }
        }

        // Then check if it's a table name directly
        for ref in references {
            if ref.tableName.lowercased() == lowerName {
                return ref.tableName
            }
        }

        // Finally check against known tables
        for table in tables {
            if table.name.lowercased() == lowerName {
                return table.name
            }
        }

        return nil
    }

    // MARK: - AI Schema Context

    func buildSchemaContextForAI(settings: AISettings) async -> String? {
        guard !tables.isEmpty, let connection = connectionInfo else { return nil }

        var columnsByTable: [String: [ColumnInfo]] = [:]
        let tablesToFetch = Array(tables.prefix(settings.maxSchemaTables))
        for table in tablesToFetch {
            let columns = await getColumns(for: table.name)
            if !columns.isEmpty {
                columnsByTable[table.name.lowercased()] = columns
            }
        }

        let dbType = connection.type
        let dbName = connection.database
        let capturedTables = tables
        let idQuote = await MainActor.run {
            PluginManager.shared.sqlDialect(for: dbType)?.identifierQuote ?? "\""
        }

        return await MainActor.run {
            AISchemaContext.buildSystemPrompt(
                databaseType: dbType,
                databaseName: dbName,
                tables: capturedTables,
                columnsByTable: columnsByTable,
                foreignKeys: [:],
                currentQuery: nil,
                queryResults: nil,
                settings: settings,
                identifierQuote: idQuote
            )
        }
    }

    // MARK: - Completion Items

    /// Get completion items for tables
    func tableCompletionItems() async -> [SQLCompletionItem] {
        let tableData = tables.map { (name: $0.name, isView: $0.type == .view) }
        return await MainActor.run {
            tableData.map { SQLCompletionItem.table($0.name, isView: $0.isView) }
        }
    }

    /// Get completion items for columns of a specific table
    func columnCompletionItems(for tableName: String) async -> [SQLCompletionItem] {
        let columns = await getColumns(for: tableName)
        let columnData = columns.map { col in
            (name: col.name, type: col.dataType, isPK: col.isPrimaryKey,
             isNullable: col.isNullable, defaultValue: col.defaultValue, comment: col.comment)
        }
        return await MainActor.run {
            columnData.map {
                SQLCompletionItem.column(
                    $0.name, dataType: $0.type, tableName: tableName,
                    isPrimaryKey: $0.isPK, isNullable: $0.isNullable,
                    defaultValue: $0.defaultValue, comment: $0.comment
                )
            }
        }
    }

    /// Get completion items for all columns of tables in scope
    func allColumnsInScope(for references: [TableReference]) async -> [SQLCompletionItem] {
        // swiftlint:disable:next large_tuple
        var itemDataBuilder: [(
            label: String, insertText: String, type: String, table: String,
            isPK: Bool, isNullable: Bool, defaultValue: String?, comment: String?
        )] = []

        let hasMultipleRefs = references.count > 1
        for ref in references {
            let columns = await getColumns(for: ref.tableName)
            let refId = ref.identifier
            for column in columns {
                let label = hasMultipleRefs ? "\(refId).\(column.name)" : column.name
                let insertText = hasMultipleRefs ? "\(refId).\(column.name)" : column.name

                itemDataBuilder.append(
                    (
                        label: label, insertText: insertText, type: column.dataType,
                        table: ref.tableName, isPK: column.isPrimaryKey,
                        isNullable: column.isNullable, defaultValue: column.defaultValue,
                        comment: column.comment
                    ))
            }
        }

        // Capture as immutable for Sendable compliance
        let itemData = itemDataBuilder

        return await MainActor.run {
            itemData.map {
                SQLCompletionItem.column(
                    $0.label, dataType: $0.type, tableName: $0.table,
                    isPrimaryKey: $0.isPK, isNullable: $0.isNullable,
                    defaultValue: $0.defaultValue, comment: $0.comment
                )
            }
        }
    }
}
