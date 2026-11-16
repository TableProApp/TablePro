//
//  RedshiftCatalogExport.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProLogRedaction
import TableProPluginKit

// Redshift's catalog reads for listing and export, over whichever connection runs them. External schemas list their
// tables and columns only in the svv_external_* views.
nonisolated struct RedshiftCatalogExport: Sendable {
    typealias Read = @Sendable (_ statement: String) async throws -> [[PluginCellValue]]

    static let tableDDLIncludesForeignKeys = true

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "RedshiftPluginDriver")

    let read: Read
    let currentSchema: String
    // The database the connection is on: the svv_external_* views carry rows for every database on the cluster.
    let database: String
    let serverVersionNumber: Int32
    let externalSchemas: Set<String>

    init(
        read: @escaping Read,
        currentSchema: String,
        database: String,
        serverVersionNumber: Int32,
        externalSchemas: Set<String>
    ) {
        self.read = read
        self.currentSchema = currentSchema
        self.database = database
        self.serverVersionNumber = serverVersionNumber
        self.externalSchemas = externalSchemas
    }

    // A cluster with no external catalog answers this in one cheap read.
    static func externalSchemaNames(read: Read) async throws -> Set<String> {
        Set(try await read(RedshiftExternalSchemaQueries.listExternalSchemaNames).compactMap { $0.first?.asText })
    }

    private func isExternalSchema(_ schema: String) -> Bool {
        externalSchemas.contains(schema)
    }

    // MARK: - Tables

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let resolvedSchema = schema ?? currentSchema
        let localTables = try await read(RedshiftTableCatalog.listingQuery(schema: resolvedSchema))
            .compactMap { RedshiftTableCatalog.table(fromListingRow: $0.map(\.asText)) }

        guard isExternalSchema(resolvedSchema) else { return localTables }

        let externalTables = await fetchExternalTables(schema: resolvedSchema)
        guard !externalTables.isEmpty else { return localTables }

        let localNames = Set(localTables.map(\.name))
        let merged = localTables + externalTables.filter { !localNames.contains($0.name) }
        return merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func fetchTables(inSchemas schemas: [String]) async throws -> [PluginTableInfo] {
        guard !schemas.isEmpty else { return [] }
        var tables = try await read(RedshiftTableCatalog.listingQuery(inSchemas: schemas))
            .compactMap { RedshiftTableCatalog.table(fromListingRow: $0.map(\.asText)) }
        for schema in schemas where isExternalSchema(schema) {
            let localNames = Set(tables.lazy.filter { $0.schema == schema }.map(\.name))
            tables += await fetchExternalTables(schema: schema).filter { !localNames.contains($0.name) }
        }
        return tables
    }

    private func fetchExternalTables(schema: String) async -> [PluginTableInfo] {
        do {
            let query = RedshiftExternalSchemaQueries.listExternalTables(schema: schema, database: database)
            return try await read(query).compactMap { row -> PluginTableInfo? in
                guard let name = row[0].asText else { return nil }
                let rawType = row.count > 1 ? row[1].asText : nil
                return PluginTableInfo(
                    name: name,
                    type: RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: rawType),
                    schema: schema
                )
            }
        } catch {
            Self.logger.warning(
                "svv_external_tables failed for schema \(schema, privacy: .private(mask: .hash)); listing local tables only: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return []
        }
    }

    // MARK: - Columns

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let resolvedSchema = schema ?? currentSchema
        if isExternalSchema(resolvedSchema) {
            let external = await fetchExternalColumns(schema: resolvedSchema, table: table)
            if !external.isEmpty { return external }
        }
        return try await fetchLocalColumns(table: table, schema: resolvedSchema)
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let resolvedSchema = schema ?? currentSchema
        if isExternalSchema(resolvedSchema) {
            let external = await fetchExternalAllColumns(schema: resolvedSchema)
            if !external.isEmpty { return external }
        }
        return try await fetchLocalAllColumns(schema: resolvedSchema)
    }

    private func fetchExternalColumns(schema: String, table: String) async -> [PluginColumnInfo] {
        do {
            let query = RedshiftExternalSchemaQueries.listExternalColumns(schema: schema, table: table, database: database)
            return try await read(query).compactMap { row -> PluginColumnInfo? in
                guard row.count >= 2, let name = row[0].asText, let dataType = row[1].asText else { return nil }
                return Self.externalColumn(name: name, dataType: dataType, row: row, typeIndex: 1)
            }
        } catch {
            Self.logger.warning(
                "svv_external_columns failed for schema \(schema, privacy: .private(mask: .hash)): \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return []
        }
    }

    private func fetchExternalAllColumns(schema: String) async -> [String: [PluginColumnInfo]] {
        do {
            let query = RedshiftExternalSchemaQueries.listExternalColumns(schema: schema, table: nil, database: database)
            var allColumns: [String: [PluginColumnInfo]] = [:]
            for row in try await read(query) {
                guard row.count >= 3,
                      let tableName = row[0].asText,
                      let name = row[1].asText,
                      let dataType = row[2].asText
                else { continue }
                let column = Self.externalColumn(name: name, dataType: dataType, row: row, typeIndex: 2)
                allColumns[tableName, default: []].append(column)
            }
            return allColumns
        } catch {
            Self.logger.warning(
                "svv_external_columns failed for schema \(schema, privacy: .private(mask: .hash)): \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return [:]
        }
    }

    // External columns carry no default, charset, collation, comment or key, and `external_type` is a Hive type
    // string that reaches the UI unparsed so nested `struct` and `array` declarations survive.
    private static func externalColumn(
        name: String,
        dataType: String,
        row: [PluginCellValue],
        typeIndex: Int
    ) -> PluginColumnInfo {
        let nullableIndex = typeIndex + 1
        let partKeyIndex = typeIndex + 2
        let rawNullable = row.count > nullableIndex ? row[nullableIndex].asText : nil
        let rawPartKey = row.count > partKeyIndex ? row[partKeyIndex].asText : nil
        return PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: RedshiftExternalSchemaQueries.classifyIsNullable(raw: rawNullable),
            isPrimaryKey: false,
            extra: RedshiftExternalSchemaQueries.partitionKeyDescription(rawPartKey: rawPartKey)
        )
    }

    private func fetchLocalColumns(table: String, schema: String) async throws -> [PluginColumnInfo] {
        try await read(RedshiftSchemaQueries.columnsQuery(schema: schema, table: table)).compactMap { row in
            guard row.count >= 4 else { return nil }
            return Self.localColumn(row, tableNameOffset: 0)
        }
    }

    private func fetchLocalAllColumns(schema: String) async throws -> [String: [PluginColumnInfo]] {
        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in try await read(RedshiftSchemaQueries.columnsQuery(schema: schema, table: nil)) {
            guard row.count >= 5,
                  let tableName = row[0].asText,
                  let column = Self.localColumn(row, tableNameOffset: 1)
            else { continue }
            allColumns[tableName, default: []].append(column)
        }
        return allColumns
    }

    private static func localColumn(_ row: [PluginCellValue], tableNameOffset offset: Int) -> PluginColumnInfo? {
        guard let name = row[offset].asText,
              let rawDataType = row[offset + 1].asText
        else { return nil }

        let udtName = row.count > offset + 6 ? row[offset + 6].asText : nil
        let dataType: String
        if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
            dataType = "ENUM(\(udt))"
        } else {
            dataType = rawDataType.uppercased()
        }

        let collation = row.count > offset + 4 ? row[offset + 4].asText : nil
        let comment = row.count > offset + 5 ? row[offset + 5].asText : nil
        let charset: String? = {
            guard let coll = collation, coll.contains(".") else { return nil }
            return coll.components(separatedBy: ".").last
        }()

        return PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: row[offset + 2].asText == "YES",
            isPrimaryKey: row.count > offset + 7 && row[offset + 7].asText == "YES",
            defaultValue: row[offset + 3].asText,
            charset: charset,
            collation: collation,
            comment: comment?.isEmpty == false ? comment : nil
        )
    }

    // MARK: - Keys

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let query = RedshiftTableCatalog.keysQuery(schema: schema ?? currentSchema, table: table)
        return RedshiftTableCatalog.keys(fromRows: try await read(query).map { $0.map(\.asText) })
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let query = PostgreSQLCatalogForeignKeys.query(
            schema: schema ?? currentSchema,
            table: table,
            excludesPartitionClones: PostgreSQLCatalogForeignKeys.excludesPartitionClones(
                serverVersionNumber: serverVersionNumber
            )
        )
        return PostgreSQLCatalogForeignKeys.foreignKeys(from: try await read(query).map { $0.map(\.asText) })
    }

    // MARK: - Definitions

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let resolvedSchema = schema ?? currentSchema
        guard !isExternalSchema(resolvedSchema) else { return nil }
        let query = """
            SELECT tbl_rows
            FROM svv_table_info
            WHERE "table" = \(PostgreSQLObjectQueries.quoteLiteral(table))
              AND schema = \(PostgreSQLObjectQueries.quoteLiteral(resolvedSchema))
            """
        guard let firstRow = try await read(query).first, let value = firstRow[0].asText, let count = Int(value) else {
            return nil
        }
        return count >= 0 ? count : nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let resolvedSchema = schema ?? currentSchema
        let quotedTable = PostgreSQLObjectQueries.quoteIdentifier(table)
        let quotedSchema = PostgreSQLObjectQueries.quoteIdentifier(resolvedSchema)

        do {
            let showRows = try await read("SHOW TABLE \(quotedSchema).\(quotedTable)")
            if let firstRow = showRows.first, let ddl = firstRow[0].asText, !ddl.isEmpty {
                return ddl
            }
        } catch {
            Self.logger.debug("SHOW TABLE not available, falling back to manual reconstruction")
        }

        // pg_attribute lists a view's columns as it lists a table's, so a view is looked up before the reconstruction.
        let view = try await read(Self.viewDefinitionQuery(view: table, schema: resolvedSchema))
        if let ddl = view.first?[safe: 0]?.asText {
            return ddl
        }

        let columnDefs = try await read(Self.columnDefinitionsQuery(table: table, schema: resolvedSchema))
            .compactMap { $0[0].asText }
        guard !columnDefs.isEmpty else {
            throw PostgreSQLCatalogReadError(message: "Failed to fetch DDL for table '\(table)'")
        }

        var parts = columnDefs
        parts.append(contentsOf: try await foreignKeyClauses(table: table, schema: schema))

        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " + parts.joined(separator: ",\n  ") + "\n);"

        do {
            var suffixes: [String] = []
            for idx in try await fetchIndexes(table: table, schema: schema) {
                if idx.type == "DISTKEY", let col = idx.columns.first {
                    suffixes.append("DISTKEY(\(col))")
                }
                if idx.type == "SORTKEY" {
                    suffixes.append("SORTKEY(\(idx.columns.joined(separator: ", ")))")
                }
            }
            if !suffixes.isEmpty {
                return ddl + "\n" + suffixes.joined(separator: "\n") + ";"
            }
        } catch {
            Self.logger.debug("Could not fetch DISTKEY/SORTKEY info: \(error.localizedDescription)")
        }
        return ddl
    }

    // `SHOW TABLE` declares foreign keys inline, so the reconstruction does too. A failed lookup throws: an empty
    // answer would read as a table with no foreign keys.
    private func foreignKeyClauses(table: String, schema: String?) async throws -> [String] {
        let quote = PostgreSQLObjectQueries.quoteIdentifier
        var orderedNames: [String] = []
        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for foreignKey in try await fetchForeignKeys(table: table, schema: schema) {
            if grouped[foreignKey.name] == nil { orderedNames.append(foreignKey.name) }
            grouped[foreignKey.name, default: []].append(foreignKey)
        }
        return orderedNames.compactMap { name in
            guard let group = grouped[name], let first = group.first else { return nil }
            let columns = group.map { quote($0.column) }.joined(separator: ", ")
            let referencedColumns = group.map { quote($0.referencedColumn) }.joined(separator: ", ")
            let referencedSchema = first.referencedSchema.flatMap { $0.isEmpty ? nil : $0 }
            let referencedTable = referencedSchema.map {
                "\(quote($0)).\(quote(first.referencedTable))"
            } ?? quote(first.referencedTable)
            return "CONSTRAINT \(quote(name)) FOREIGN KEY (\(columns))"
                + " REFERENCES \(referencedTable) (\(referencedColumns))"
        }
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let rows = try await read(Self.viewDefinitionQuery(view: view, schema: schema ?? currentSchema))
        guard let firstRow = rows.first, let ddl = firstRow[0].asText else {
            throw PostgreSQLCatalogReadError(message: "Failed to fetch definition for view '\(view)'")
        }
        return ddl
    }

    private static func viewDefinitionQuery(view: String, schema: String) -> String {
        """
        SELECT 'CREATE OR REPLACE VIEW ' || pg_catalog.quote_ident(schemaname) || '.' || pg_catalog.quote_ident(viewname) || ' AS ' || E'\\n' || definition AS ddl
        FROM pg_catalog.pg_views
        WHERE viewname = \(PostgreSQLObjectQueries.quoteLiteral(view))
          AND schemaname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
        """
    }

    private static func columnDefinitionsQuery(table: String, schema: String) -> String {
        """
        SELECT
            pg_catalog.quote_ident(a.attname) || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod) ||
            CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
            CASE WHEN a.atthasdef THEN ' DEFAULT ' || pg_catalog.pg_get_expr(d.adbin, d.adrelid) ELSE '' END
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
        WHERE c.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
          AND n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """
    }
}
