import Foundation
import TableProPluginKit
import TableProSpannerCore

extension SpannerPluginDriver {
    var providesBulkColumnFetch: Bool { true }

    var providesBulkIndexFetch: Bool { true }

    var providesBulkForeignKeyFetch: Bool { true }

    func fetchSchemas() async throws -> [String] {
        try await perform {
            let dialect = self.dialect
            let rows = try await self.requireExecutor().read(SpannerCatalogSQL.schemas(dialect: dialect))
            return SpannerCatalogParser.schemas(rows, dialect: dialect).map(self.presentedSchema)
        }
    }

    func fetchDatabases() async throws -> [String] {
        [try settingsDatabaseId()]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let sqlSchema = sqlSchema(schema)
        return try await perform {
            let statement = SpannerCatalogSQL.tables(schema: sqlSchema, dialect: self.dialect)
            let rows = try await self.requireExecutor().read(statement)
            return SpannerCatalogParser.tables(rows).map { table in
                PluginTableInfo(
                    name: table.name,
                    type: table.isView ? "VIEW" : "TABLE",
                    schema: self.presentedSchema(table.schema)
                )
            }
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await columnInfos(schema: sqlSchema(schema), table: table)[table] ?? []
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await columnInfos(schema: sqlSchema(schema), table: nil)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        try await indexInfos(schema: sqlSchema(schema), table: table)[table] ?? []
    }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        try await indexInfos(schema: sqlSchema(schema), table: nil)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        try await foreignKeyInfos(schema: sqlSchema(schema), table: table)[table] ?? []
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try await foreignKeyInfos(schema: sqlSchema(schema), table: nil)
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let sqlSchema = sqlSchema(schema)
        let catalog = try await ddlCatalog()
        guard let ddl = catalog.tableDDL(schema: sqlSchema, name: table) else {
            throw SpannerDriverError.objectNotFound(table)
        }
        return ddl
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let sqlSchema = sqlSchema(schema)
        return try await ddlCatalog().indexDDL(schema: sqlSchema, table: table)
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let sqlSchema = sqlSchema(schema)
        if let ddl = try await ddlCatalog().viewDDL(schema: sqlSchema, name: view) {
            return ddl
        }
        let definition = try await perform {
            let statement = SpannerCatalogSQL.viewDefinition(schema: sqlSchema, name: view, dialect: self.dialect)
            return SpannerCatalogParser.viewDefinition(try await self.requireExecutor().read(statement))
        }
        guard let definition else {
            throw SpannerDriverError.objectNotFound(view)
        }
        return definition
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: dialect == .postgreSQL ? "PostgreSQL" : "GoogleSQL")
    }

    private func settingsDatabaseId() throws -> String {
        do {
            return try SpannerConnectionSettings.parse(fields: config.additionalFields).databaseId
        } catch {
            throw SpannerDriverError.wrap(error)
        }
    }

    private func ddlCatalog() async throws -> SpannerDDLCatalog {
        try await perform {
            SpannerDDLCatalog(statements: try await self.requireExecutor().databaseDDL(), dialect: self.dialect)
        }
    }

    private func columnInfos(schema: String, table: String?) async throws -> [String: [PluginColumnInfo]] {
        try await perform {
            let statement = SpannerCatalogSQL.columns(schema: schema, table: table, dialect: self.dialect)
            let columns = SpannerCatalogParser.columns(try await self.requireExecutor().read(statement))
            return Dictionary(grouping: columns, by: \.table).mapValues { $0.map(Self.pluginColumn) }
        }
    }

    private func indexInfos(schema: String, table: String?) async throws -> [String: [PluginIndexInfo]] {
        try await perform {
            let statement = SpannerCatalogSQL.indexes(schema: schema, table: table, dialect: self.dialect)
            let indexes = SpannerCatalogParser.indexes(try await self.requireExecutor().read(statement))
            return Dictionary(grouping: indexes, by: \.table).mapValues { $0.map(Self.pluginIndex) }
        }
    }

    private func foreignKeyInfos(schema: String, table: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try await perform {
            let executor = try self.requireExecutor()
            let dialect = self.dialect
            let keyRows = try await executor.read(SpannerCatalogSQL.foreignKeys(schema: schema, table: table, dialect: dialect))
            let interleaveRows = try await executor.read(
                SpannerCatalogSQL.interleaveParents(schema: schema, table: table, dialect: dialect)
            )
            let keys = SpannerCatalogParser.foreignKeys(keyRows, interleaveRows: interleaveRows)
            return Dictionary(grouping: keys, by: \.table).mapValues { group in
                group.flatMap { self.pluginForeignKeys($0) }
            }
        }
    }

    private func pluginForeignKeys(_ key: SpannerForeignKeyInfo) -> [PluginForeignKeyInfo] {
        zip(key.columns, key.referencedColumns).map { column, referencedColumn in
            PluginForeignKeyInfo(
                name: key.name,
                column: column,
                referencedTable: key.referencedTable,
                referencedColumn: referencedColumn,
                referencedSchema: presentedSchema(key.referencedSchema),
                onDelete: key.onDelete ?? "NO ACTION"
            )
        }
    }

    private static func pluginColumn(_ column: SpannerColumnInfo) -> PluginColumnInfo {
        PluginColumnInfo(
            name: column.name,
            dataType: column.spannerType,
            isNullable: column.isNullable,
            isPrimaryKey: column.isPrimaryKey,
            defaultValue: column.defaultExpression,
            identityKind: identityKind(column.identityGeneration),
            isGenerated: column.isGenerated,
            generationExpression: column.generationExpression,
            generationKind: column.isGenerated ? (column.isStored ? .stored : .virtual) : nil
        )
    }

    private static func identityKind(_ generation: String?) -> IdentityKind? {
        switch generation?.uppercased() {
        case "ALWAYS":
            return .always
        case "BY DEFAULT":
            return .byDefault
        default:
            return nil
        }
    }

    private static func pluginIndex(_ index: SpannerIndexInfo) -> PluginIndexInfo {
        PluginIndexInfo(
            name: index.name,
            columns: index.columns,
            isUnique: index.isUnique || index.isPrimaryKey,
            isPrimary: index.isPrimaryKey,
            type: index.type
        )
    }
}
