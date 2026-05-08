//
//  AIChatViewModel+SchemaContext.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension AIChatViewModel {
    struct PromptContext: Sendable {
        let databaseType: DatabaseType
        let databaseName: String
        let tables: [TableInfo]
        let columnsByTable: [String: [ColumnInfo]]
        let foreignKeys: [String: [ForeignKeyInfo]]
        let currentQuery: String?
        let queryResults: String?
        let settings: AISettings
        let identifierQuote: String
        let editorLanguage: EditorLanguage
        let queryLanguageName: String
        let connectionRules: String?
    }

    func ensureColumnsLoaded(forTable tableName: String) async {
        if let existing = columnsByTable[tableName], !existing.isEmpty { return }
        if let inFlight = inFlightColumnFetches[tableName] {
            await inFlight.value
            return
        }
        guard let connection,
              let driver = services.databaseManager.driver(for: connection.id) else { return }
        let task: Task<Void, Never> = Task { [weak self] in
            let columns: [ColumnInfo]
            do {
                columns = try await driver.fetchColumns(table: tableName)
            } catch {
                Self.logger.warning("Column fetch failed for \(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                columns = []
            }
            let fkMap: [String: [ForeignKeyInfo]]
            do {
                fkMap = try await driver.fetchForeignKeys(forTables: [tableName])
            } catch {
                Self.logger.warning("Foreign key fetch failed for \(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                fkMap = [:]
            }
            guard !Task.isCancelled, let self else { return }
            self.columnsByTable[tableName] = columns
            if let fks = fkMap[tableName] {
                self.foreignKeysByTable[tableName] = fks
            }
            self.inFlightColumnFetches[tableName] = nil
        }
        inFlightColumnFetches[tableName] = task
        await task.value
    }

    func ensureSchemaLoaded() async {
        if let inFlight = inFlightSchemaLoad {
            await inFlight.value
            return
        }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runSchemaLoad()
        }
        inFlightSchemaLoad = task
        await task.value
        inFlightSchemaLoad = nil
    }

    func ensureSavedQueryLoaded(id: UUID) async {
        if cachedSavedQueries[id] != nil { return }
        if let favorite = await services.sqlFavoriteManager.fetchFavorite(id: id) {
            cachedSavedQueries[id] = favorite
        }
    }

    func primeAttachmentData(for item: ContextItem) async {
        switch item {
        case .schema:
            await ensureSchemaLoaded()
        case .table(_, let name):
            await ensureColumnsLoaded(forTable: name)
        case .savedQuery(let id, _):
            await ensureSavedQueryLoaded(id: id)
        case .currentQuery, .queryResult, .file:
            break
        }
    }

    private func runSchemaLoad() async {
        guard let connection,
              let driver = services.databaseManager.driver(for: connection.id) else { return }
        let settings = services.appSettings.ai
        let tablesToFetch = Array(tables.prefix(settings.maxSchemaTables))
        guard !tablesToFetch.isEmpty else { return }

        await withTaskGroup(of: (String, [ColumnInfo]).self) { group in
            for table in tablesToFetch where (columnsByTable[table.name] ?? []).isEmpty {
                let name = table.name
                group.addTask {
                    do {
                        let cols = try await driver.fetchColumns(table: name)
                        return (name, cols)
                    } catch {
                        Self.logger.warning("Schema column fetch failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return (name, [])
                    }
                }
            }
            for await (name, cols) in group {
                columnsByTable[name] = cols
            }
        }

        guard !Task.isCancelled else { return }

        let needsFKFetch = tablesToFetch.contains { foreignKeysByTable[$0.name] == nil }
        guard needsFKFetch else { return }
        do {
            let fkMap = try await driver.fetchForeignKeys(forTables: tablesToFetch.map(\.name))
            for (name, fks) in fkMap {
                foreignKeysByTable[name] = fks
            }
        } catch {
            Self.logger.warning("Foreign key bulk fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func capturePromptContext(settings: AISettings) -> PromptContext? {
        guard let connection else { return nil }
        return PromptContext(
            databaseType: connection.type,
            databaseName: services.databaseManager.activeDatabaseName(for: connection),
            tables: tables,
            columnsByTable: columnsByTable,
            foreignKeys: foreignKeysByTable,
            currentQuery: settings.includeCurrentQuery ? currentQuery : nil,
            queryResults: settings.includeQueryResults ? queryResults : nil,
            settings: settings,
            identifierQuote: services.pluginManager.sqlDialect(for: connection.type)?.identifierQuote ?? "\"",
            editorLanguage: services.pluginManager.editorLanguage(for: connection.type),
            queryLanguageName: services.pluginManager.queryLanguageName(for: connection.type),
            connectionRules: connection.aiRules
        )
    }

    func resolveConnectionPolicy(settings: AISettings) -> AIConnectionPolicy? {
        let policy = connection?.aiPolicy ?? settings.defaultConnectionPolicy

        if policy == .askEachTime {
            if let connectionID = connection?.id, sessionApprovedConnections.contains(connectionID) {
                return .alwaysAllow
            }
            return .askEachTime
        }

        return policy
    }

    func renderedSchemaSection() -> String? {
        guard !tables.isEmpty else { return nil }
        let settings = services.appSettings.ai
        let identifierQuote = connection.flatMap {
            services.pluginManager.sqlDialect(for: $0.type)?.identifierQuote
        } ?? "\""
        let section = AISchemaContext.buildSchemaSection(
            tables: tables,
            columnsByTable: columnsByTable,
            foreignKeys: foreignKeysByTable,
            maxTables: settings.maxSchemaTables,
            identifierQuote: identifierQuote
        )
        return section.isEmpty ? nil : section
    }
}
