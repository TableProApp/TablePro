//
//  AIChatViewModel+SchemaContext.swift
//  TablePro
//

import Foundation
import os
import TableProAutocomplete
import TableProPluginKit

extension AIChatViewModel {
    struct PromptContext: Sendable {
        let databaseType: DatabaseType
        let databaseName: String
        let tables: [AISchemaTable]
        let defaultSchema: String?
        let currentQuery: String?
        let queryResults: String?
        let settings: AISettings
        let identifierQuote: String
        let editorLanguage: EditorLanguage
        let queryLanguageName: String
        let connectionRules: String?
    }

    func ensureColumnsLoaded(forTable tableName: String) async {
        dropSchemaCacheIfScopeChanged()
        // The ranking's bulk read fills columns without foreign keys, so each is checked on its own.
        let needsColumns = (columnsByTable[tableName] ?? []).isEmpty
        if !needsColumns, foreignKeysByTable[tableName] != nil { return }
        if let inFlight = inFlightColumnFetches[tableName] {
            await inFlight.value
            return
        }
        guard let connection else { return }
        let connId = connection.id
        let scope = schemaCacheScope
        let task: Task<Void, Never> = Task { [weak self] in
            var columns: [ColumnInfo]?
            if needsColumns {
                do {
                    columns = try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connId) { driver in
                        try await driver.fetchColumns(table: tableName)
                    }
                } catch {
                    Self.logger.warning("Column fetch failed for \(tableName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)")
                    columns = []
                }
            }
            let fkMap: [String: [ForeignKeyInfo]]?
            do {
                fkMap = try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connId) { driver in
                    try await driver.fetchForeignKeys(forTables: [tableName])
                }
            } catch {
                Self.logger.warning("Foreign key fetch failed for \(tableName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)")
                fkMap = nil
            }
            guard !Task.isCancelled, let self, self.schemaCacheScope == scope else { return }
            if let columns {
                self.columnsByTable[tableName] = columns
            }
            if let fkMap {
                self.foreignKeysByTable[tableName] = fkMap[tableName] ?? []
            }
            self.inFlightColumnFetches[tableName] = nil
        }
        inFlightColumnFetches[tableName] = task
        await task.value
    }

    func ensureSchemaLoaded(relevantTo question: String? = nil) async {
        dropSchemaCacheIfScopeChanged()
        if let inFlight = inFlightSchemaLoad {
            await inFlight.value
            // The load in flight fetched for the previous order; a new order may need other tables.
            guard question != nil else { return }
        }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            if let question {
                await self.loadEveryColumnForRanking()
                guard !Task.isCancelled else { return }
                await self.prioritizeSchema(for: question)
                guard !Task.isCancelled else { return }
            }
            await self.runSchemaLoad()
        }
        inFlightSchemaLoad = task
        await task.value
        if inFlightSchemaLoad == task {
            inFlightSchemaLoad = nil
        }
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
        case .currentQuery, .queryResult, .file, .queryContext:
            break
        }
    }

    private func runSchemaLoad() async {
        guard let connection else { return }
        let connId = connection.id
        let scope = schemaCacheScope
        let settings = services.appSettings.ai
        let tablesToFetch = Array(orderedTables().prefix(settings.maxSchemaTables))
        guard !tablesToFetch.isEmpty else { return }

        await withTaskGroup(of: (String, [ColumnInfo]).self) { group in
            for table in tablesToFetch where (columnsByTable[table.name] ?? []).isEmpty {
                let name = table.name
                group.addTask {
                    do {
                        let cols = try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connId, workload: .bulk) { driver in
                            try await driver.fetchColumns(table: name)
                        }
                        return (name, cols)
                    } catch {
                        Self.logger.warning("Schema column fetch failed for \(name, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)")
                        return (name, [])
                    }
                }
            }
            for await (name, cols) in group where schemaCacheScope == scope {
                columnsByTable[name] = cols
            }
        }

        guard !Task.isCancelled, schemaCacheScope == scope else { return }

        let needsFKFetch = tablesToFetch.contains { foreignKeysByTable[$0.name] == nil }
        guard needsFKFetch else { return }
        do {
            let fkMap = try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connId, workload: .bulk) { driver in
                try await driver.fetchForeignKeys(forTables: tablesToFetch.map(\.name))
            }
            guard schemaCacheScope == scope else { return }
            for table in tablesToFetch {
                foreignKeysByTable[table.name] = fkMap[table.name] ?? []
            }
        } catch {
            Self.logger.warning("Foreign key bulk fetch failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    func capturePromptContext(settings: AISettings) -> PromptContext? {
        guard let connection else { return nil }
        return PromptContext(
            databaseType: connection.type,
            databaseName: services.databaseManager.browseDatabaseName(for: connection),
            tables: schemaTables(),
            defaultSchema: defaultSchema(for: connection),
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
        let policy = connection.map {
            AIConnectionAccessGate.policy(
                for: $0.id,
                connectionStorage: services.connectionStorage,
                databaseManager: services.databaseManager,
                defaultPolicy: settings.defaultConnectionPolicy,
                unsavedCopy: $0
            ) ?? .never
        } ?? settings.defaultConnectionPolicy

        if policy == .askEachTime {
            if let connectionID = connection?.id, services.aiAccessApprovals.isApproved(connectionID) {
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
            tables: schemaTables(),
            defaultSchema: connection.flatMap { defaultSchema(for: $0) },
            maxTables: settings.maxSchemaTables,
            identifierQuote: identifierQuote
        )
        return section.isEmpty ? nil : section
    }

    /// `tables` lists the one schema the session browses, where a table name is unique, so the
    /// name-keyed column and foreign key maps join to it by name.
    private func schemaTables() -> [AISchemaTable] {
        orderedTables().map { table in
            AISchemaTable(
                table: table,
                columns: columnsByTable[table.name] ?? [],
                foreignKeys: foreignKeysByTable[table.name] ?? []
            )
        }
    }

    private func prioritizeSchema(for question: String) async {
        let input = AISchemaRankingInput(
            tables: tables,
            columnsByTable: columnsByTable,
            question: question,
            queryReferences: editorQueryReferences(),
            defaultSchema: connection.flatMap { defaultSchema(for: $0) },
            maxTables: services.appSettings.ai.maxSchemaTables
        )
        guard input.tables.count > input.maxTables else { return }
        let scope = schemaCacheScope
        let ranked = await AISchemaContext.rankOffMainActor(input, using: schemaRanker)
        guard !Task.isCancelled, schemaCacheScope == scope, !ranked.isEmpty else { return }
        relevantTableNames = ranked
    }

    // The editor steers the order only while the model is shown the editor's query.
    private func editorQueryReferences() -> [TableReference] {
        guard services.appSettings.ai.includeCurrentQuery,
              let connection,
              let query = currentQuery, !query.isEmpty,
              services.pluginManager.editorLanguage(for: connection.type) == .sql
        else { return [] }
        return AISchemaContext.referencedTables(
            in: AISchemaContext.carriedQuery(query),
            grammar: SQLLexicalResolver.executionGrammar(for: connection.type, connectionId: connection.id)
        )
    }

    private func loadEveryColumnForRanking() async {
        guard let connection else { return }
        let tableCount = tables.count
        guard tableCount > services.appSettings.ai.maxSchemaTables,
              tableCount <= SQLSchemaProvider.maxCachedTables,
              bulkColumnReadTableCount != tableCount
        else { return }
        bulkColumnReadTableCount = tableCount
        let scope = schemaCacheScope
        let allColumns: [String: [ColumnInfo]]?
        do {
            allColumns = try await DatabaseManager.shared.withBrowseMetadataDriver(
                connectionId: connection.id,
                workload: .bulk
            ) { driver in
                // A driver without a bulk read would fall back to one query per table.
                guard driver.providesBulkColumnFetch else { return nil }
                return try await driver.fetchAllColumns()
            }
        } catch {
            Self.logger.warning("Bulk column fetch failed: \(error.publicLogShape, privacy: .public)")
            if schemaCacheScope == scope {
                bulkColumnReadTableCount = nil
            }
            return
        }
        guard let allColumns, !Task.isCancelled, schemaCacheScope == scope else { return }
        // A name that differs only by case is trusted only when it can mean one table, or a
        // zero-column `orders` would take a quoted `"Orders"`'s columns.
        let foldedTableCounts = Dictionary(tables.map { ($0.name.lowercased(), 1) }, uniquingKeysWith: +)
        let byFoldedName = Dictionary(grouping: allColumns, by: { $0.key.lowercased() })
            .compactMapValues { $0.count == 1 ? $0[0].value : nil }
        var merged = columnsByTable
        // A table the read left out, such as a SQLite view, stays unknown, so the ranker never
        // takes this read for a complete one.
        for table in tables where (merged[table.name] ?? []).isEmpty {
            let folded = table.name.lowercased()
            if let columns = allColumns[table.name] ?? (foldedTableCounts[folded] == 1 ? byFoldedName[folded] : nil) {
                merged[table.name] = columns
            }
        }
        columnsByTable = merged
    }

    // A session outlives a database or schema switch, so its column cache belongs to the scope it
    // was read in.
    private func dropSchemaCacheIfScopeChanged() {
        let scope = connection.map { connection in
            [
                connection.id.uuidString,
                services.databaseManager.browseDatabaseName(for: connection),
                defaultSchema(for: connection) ?? ""
            ].joined(separator: "\u{1F}")
        }
        guard scope != schemaCacheScope else { return }
        schemaCacheScope = scope
        columnsByTable = [:]
        foreignKeysByTable = [:]
        relevantTableNames = []
        bulkColumnReadTableCount = nil
        inFlightColumnFetches.removeAll()
        inFlightSchemaLoad?.cancel()
        inFlightSchemaLoad = nil
    }

    private func orderedTables() -> [TableInfo] {
        let all = tables
        guard !relevantTableNames.isEmpty else { return all }
        let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let relevant = relevantTableNames.compactMap { byName[$0] }
        let picked = Set(relevant.map(\.name))
        return relevant + all.filter { !picked.contains($0.name) }
    }

    private func defaultSchema(for connection: DatabaseConnection) -> String? {
        connection.type.implicitSchemaName
            ?? services.databaseManager.session(for: connection.id)?.browseSchema
    }
}
