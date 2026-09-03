//
//  PostgreSQLPluginDriver.swift
//  PostgreSQLDriverPlugin
//
//  PostgreSQL PluginDatabaseDriver implementation.
//  Adapted from TablePro's PostgreSQLDriver for the plugin architecture.
//

import Foundation
import os
import TableProPluginKit

class PostgreSQLPluginDriver: LibPQBackedDriver, @unchecked Sendable {
    let core: LibPQDriverCore

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "PostgreSQLPluginDriver")

    private static let undefinedTableSQLState = PostgreSQLTableListingLadder.undefinedTableSQLState
    private static let undefinedFunctionSQLState = PostgreSQLTableListingLadder.undefinedFunctionSQLState

    private var catalogPresence: PostgreSQLCatalogPresence?

    var serverVersionNumber: Int32 { core.serverVersionNumber }
    var versionedCapabilities: PostgreSQLCapabilities {
        PostgreSQLCapabilities(serverVersion: core.serverVersionNumber)
    }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .cancelQuery,
            .batchExecute,
            .materializedViews,
            .foreignTables,
            .storedProcedures,
            .userFunctions,
            .userManagement,
            .schemaCompare,
            .dataCompare
        ]
    }

    init(config: DriverConnectionConfig, singleConnectionMode: Bool = false) {
        self.core = LibPQDriverCore(config: config, singleConnectionMode: singleConnectionMode)
    }

    // MARK: - Connection

    func connect() async throws {
        core.onPostConnect = { [weak self] in
            await self?.probeCatalogPresence()
            await self?.probePostgisOids()
            await self?.probeEnumOids()
        }
        try await core.connect()
    }

    private func probeCatalogPresence() async {
        do {
            let result = try await core.execute(query: PostgreSQLCatalogPresence.probeQuery)
            let relationNames = result.rows.compactMap { $0.first?.asText }
            catalogPresence = PostgreSQLCatalogPresence(relationNames: relationNames)
        } catch {
            Self.logger.debug("Catalog presence probe failed; using version-based capabilities: \(error.localizedDescription)")
        }
    }

    private func probePostgisOids() async {
        do {
            let result = try await core.execute(query: PostGISSpatialRewrite.probeQuery)
            var map: [UInt32: String] = [:]
            for row in result.rows {
                guard row.count >= 2,
                      let oidText = row[0].asText,
                      let oid = UInt32(oidText),
                      let typname = row[1].asText else { continue }
                map[oid] = typname
            }
            core.setPostgisOidMap(map)
        } catch {
            Self.logger.debug("PostGIS OID probe failed; spatial rewrite disabled for this session: \(error.localizedDescription)")
        }
    }

    private func includesMaterializedViews() -> Bool {
        catalogPresence?.hasMaterializedViews ?? versionedCapabilities.hasMaterializedViewsCatalog
    }

    private func includesForeignTables() -> Bool {
        catalogPresence?.hasForeignTables ?? versionedCapabilities.hasForeignTablesCatalog
    }

    private func includesSequencesCatalog() -> Bool {
        catalogPresence?.hasSequences ?? versionedCapabilities.hasSequencesCatalog
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - Foreign Keys

    func foreignKeyDisableStatements() -> [String]? {
        ["SET session_replication_role = replica"]
    }

    func foreignKeyEnableStatements() -> [String]? {
        ["SET session_replication_role = DEFAULT"]
    }

    /// A duplicated database arrives with `public` alone, so every other schema its tables are
    /// qualified with has to be made before the first `CREATE TABLE` names one.
    func createSchemaStatement(name: String) -> String? {
        "CREATE SCHEMA IF NOT EXISTS \(quoteIdentifier(name))"
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String]? {
        ["VACUUM", "ANALYZE", "REINDEX", "CLUSTER"]
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        let target = table.map { quoteIdentifier($0) }
        switch operation {
        case "VACUUM":
            var opts: [String] = []
            if options["full"] == "true" { opts.append("FULL") }
            if options["analyze"] == "true" { opts.append("ANALYZE") }
            if options["verbose"] == "true" { opts.append("VERBOSE") }
            let optClause = opts.isEmpty ? "" : "(\(opts.joined(separator: ", "))) "
            return [target.map { "VACUUM \(optClause)\($0)" } ?? "VACUUM"]
        case "ANALYZE":
            return [target.map { "ANALYZE \($0)" } ?? "ANALYZE"]
        case "REINDEX":
            return [target.map { "REINDEX TABLE \($0)" } ?? "REINDEX DATABASE CONCURRENTLY"]
        case "CLUSTER":
            return target.map { ["CLUSTER \($0)"] }
        default:
            return nil
        }
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS TEXT)"
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        func query(_ attempt: PostgreSQLTableListingAttempt) -> String {
            PostgreSQLSchemaQueries.fetchTables(
                schemaLiteral: schemaLiteral,
                includeMaterializedViews: attempt.includeOptionalCatalogs && includesMaterializedViews(),
                includeForeignTables: attempt.includeOptionalCatalogs && includesForeignTables(),
                includeComments: attempt.includeComments,
                includePartitionAwareness: attempt.includePartitionAwareness
            )
        }

        var result: PluginQueryResult?
        for attempt in PostgreSQLTableListingLadder.degradableAttempts where result == nil {
            do {
                result = try await execute(query: query(attempt))
            } catch let error as LibPQPluginError where PostgreSQLTableListingLadder.isDegradable(sqlState: error.sqlState) {
                Self.logger.debug("Table listing degrading past \(attempt.label, privacy: .public): \(error.localizedDescription)")
            }
        }
        if result == nil {
            result = try await execute(query: query(PostgreSQLTableListingLadder.leastCapableAttempt))
        }

        guard let result else { return [] }
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[0].asText else { return nil }
            let typeStr = row[1].asText ?? "BASE TABLE"
            let type: String
            switch typeStr {
            case "PARTITIONED TABLE": type = "PARTITIONED TABLE"
            case "MATERIALIZED VIEW": type = "MATERIALIZED VIEW"
            case "FOREIGN TABLE":     type = "FOREIGN TABLE"
            case "VIEW":              type = "VIEW"
            default:                  type = "TABLE"
            }
            let comment = row[safe: 2]?.asText?.nilIfEmpty
            return PluginTableInfo(name: name, type: type, comment: comment)
        }
    }

    func fetchPartitions(table: String, schema: String?) async throws -> [PluginTableInfo] {
        guard versionedCapabilities.hasDeclarativePartitioning else { return [] }
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let result = try await execute(
            query: PostgreSQLSchemaQueries.fetchPartitions(
                schemaLiteral: schemaLiteral,
                tableLiteral: escapeLiteral(table)
            )
        )
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[0].asText else { return nil }
            let isSubpartitioned = row[safe: 1]?.asText == "p"
            return PluginTableInfo(
                name: name,
                type: isSubpartitioned ? "PARTITIONED TABLE" : "TABLE",
                schema: schema ?? core.currentSchema,
                comment: nil
            )
        }
    }

    /// The namespace predicate is not optional. Without it the read matched `relname` alone, so two
    /// schemas holding a table of the same name returned each other's indexes merged into one list,
    /// which a comparison between those two schemas reports as neither side differing.
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let columnOrdering = versionedCapabilities.hasArrayPosition
            ? "ORDER BY array_position(ix.indkey, a.attnum)"
            : "ORDER BY a.attnum"
        let query = """
            SELECT
                i.relname AS index_name,
                ARRAY_AGG(a.attname \(columnOrdering)) AS columns,
                ix.indisunique AS is_unique,
                ix.indisprimary AS is_primary,
                am.amname AS index_type,
                pg_get_expr(ix.indpred, ix.indrelid) AS predicate
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
            WHERE t.relname = '\(escapeLiteral(table))' AND n.nspname = '\(schemaLiteral)'
            GROUP BY i.relname, ix.indisunique, ix.indisprimary, am.amname, ix.indpred, ix.indrelid
            ORDER BY ix.indisprimary DESC, i.relname
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { PostgreSQLIndexRow.index(from: $0, offset: 0) }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT
                con.conname,
                src_col.attname,
                ref_cl.relname AS referenced_table,
                ref_col.attname AS referenced_column,
                ref_ns.nspname AS referenced_schema,
                CASE con.confdeltype
                    WHEN 'c' THEN 'CASCADE'
                    WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT'
                    WHEN 'r' THEN 'RESTRICT'
                    ELSE 'NO ACTION'
                END AS delete_rule,
                CASE con.confupdtype
                    WHEN 'c' THEN 'CASCADE'
                    WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT'
                    WHEN 'r' THEN 'RESTRICT'
                    ELSE 'NO ACTION'
                END AS update_rule
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class src_cl ON src_cl.oid = con.conrelid
            JOIN pg_catalog.pg_namespace src_ns ON src_ns.oid = src_cl.relnamespace
            JOIN pg_catalog.pg_class ref_cl ON ref_cl.oid = con.confrelid
            JOIN pg_catalog.pg_namespace ref_ns ON ref_ns.oid = ref_cl.relnamespace
            CROSS JOIN LATERAL unnest(con.conkey, con.confkey)
                WITH ORDINALITY AS cols(src_attnum, ref_attnum, ord)
            JOIN pg_catalog.pg_attribute src_col
                ON src_col.attrelid = con.conrelid AND src_col.attnum = cols.src_attnum
            JOIN pg_catalog.pg_attribute ref_col
                ON ref_col.attrelid = con.confrelid AND ref_col.attnum = cols.ref_attnum
            WHERE con.contype = 'f'
                AND src_cl.relname = '\(escapeLiteral(table))'
                AND src_ns.nspname = '\(schemaLiteral)'
            ORDER BY con.conname, cols.ord
            """
        let result = try await execute(query: query)
        let foreignKeys: [PluginForeignKeyInfo] = result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard row.count >= 7,
                  let name = row[0].asText,
                  let column = row[1].asText,
                  let refTable = row[2].asText,
                  let refColumn = row[3].asText
            else { return nil }
            return PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[4].asText,
                onDelete: row[5].asText ?? "NO ACTION",
                onUpdate: row[6].asText ?? "NO ACTION"
            )
        }
        Self.logger.info("[fk] postgres fetchForeignKeys schema=\(schema ?? self.core.currentSchema, privacy: .public) table=\(table, privacy: .public) rows=\(result.rows.count) parsed=\(foreignKeys.count)")
        return foreignKeys
    }

    /// The same builder the schema-wide list uses, with one more predicate. Two hand-written
    /// queries over pg_trigger would be two chances to disagree about one table's triggers.
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        let resolvedSchema = schema ?? core.currentSchema
        let query = PostgreSQLObjectQueries.triggerList(schema: resolvedSchema, table: table)
        let result = try await execute(query: query)
        let triggers = result.rows.compactMap {
            Self.trigger(from: $0, fallbackSchema: resolvedSchema)
        }
        Self.logger.info("[trigger] postgres fetchTriggers schema=\(resolvedSchema, privacy: .public) table=\(table, privacy: .public) rows=\(result.rows.count) parsed=\(triggers.count)")
        return triggers
    }

    var triggerEditUsesReplace: Bool { true }

    var supportsTransactionalDDL: Bool { true }

    private func qualifiedTable(_ table: String, schema: String?) -> String {
        let resolved = schema ?? core.currentSchema
        return "\(quoteIdentifier(resolved)).\(quoteIdentifier(table))"
    }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        let qualified = qualifiedTable(table, schema: schema)
        let fn = qualifiedTable("trigger_function", schema: schema)
        return """
        CREATE OR REPLACE FUNCTION \(fn)()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $function$
        BEGIN
            -- NEW.updated_at := now();
            RETURN NEW;
        END;
        $function$;

        CREATE OR REPLACE TRIGGER \(quoteIdentifier("trigger_name"))
            BEFORE INSERT ON \(qualified)
            FOR EACH ROW
            EXECUTE FUNCTION \(fn)();
        """
    }

    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? {
        let resolvedSchema = schema ?? core.currentSchema
        let query = """
            SELECT pg_get_functiondef(t.tgfoid), pg_get_triggerdef(t.oid)
            FROM pg_catalog.pg_trigger t
            JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE t.tgname = '\(escapeLiteral(name))'
                AND c.relname = '\(escapeLiteral(table))'
                AND n.nspname = '\(escapeLiteral(resolvedSchema))'
                AND NOT t.tgisinternal
            LIMIT 1
            """
        let result = try await execute(query: query)
        guard let row = result.rows.first, row.count >= 2,
              let functionDef = row[0].asText,
              let triggerDef = row[1].asText else { return nil }
        let editableTrigger: String
        if triggerDef.range(of: "CREATE CONSTRAINT TRIGGER", options: .caseInsensitive) != nil {
            let drop = generateDropTriggerSQL(name: name, table: table, schema: schema) ?? ""
            editableTrigger = "\(drop);\n\(triggerDef)"
        } else {
            editableTrigger = triggerDef.replacingOccurrences(
                of: "CREATE TRIGGER ",
                with: "CREATE OR REPLACE TRIGGER "
            )
        }
        return "\(functionDef);\n\n\(editableTrigger);"
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        "DROP TRIGGER IF EXISTS \(quoteIdentifier(name)) ON \(qualifiedTable(table, schema: schema))"
    }

    /// PostgreSQL allows `f(integer)` and `f(text)` in one schema, so a drop that names only `f`
    /// is ambiguous and the server refuses it.
    func generateDropRoutineSQL(
        name: String,
        signature: String?,
        schema: String?,
        isFunction: Bool
    ) -> String? {
        let keyword = isFunction ? "FUNCTION" : "PROCEDURE"
        let arguments = (signature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "DROP \(keyword) IF EXISTS \(qualifiedTable(name, schema: schema))\(arguments)"
    }

    var providesBulkForeignKeyFetch: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT
                src_cl.relname AS table_name,
                con.conname,
                src_col.attname,
                ref_cl.relname AS referenced_table,
                ref_col.attname AS referenced_column,
                ref_ns.nspname AS referenced_schema,
                CASE con.confdeltype
                    WHEN 'c' THEN 'CASCADE'
                    WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT'
                    WHEN 'r' THEN 'RESTRICT'
                    ELSE 'NO ACTION'
                END AS delete_rule,
                CASE con.confupdtype
                    WHEN 'c' THEN 'CASCADE'
                    WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT'
                    WHEN 'r' THEN 'RESTRICT'
                    ELSE 'NO ACTION'
                END AS update_rule
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class src_cl ON src_cl.oid = con.conrelid
            JOIN pg_catalog.pg_namespace src_ns ON src_ns.oid = src_cl.relnamespace
            JOIN pg_catalog.pg_class ref_cl ON ref_cl.oid = con.confrelid
            JOIN pg_catalog.pg_namespace ref_ns ON ref_ns.oid = ref_cl.relnamespace
            CROSS JOIN LATERAL unnest(con.conkey, con.confkey)
                WITH ORDINALITY AS cols(src_attnum, ref_attnum, ord)
            JOIN pg_catalog.pg_attribute src_col
                ON src_col.attrelid = con.conrelid AND src_col.attnum = cols.src_attnum
            JOIN pg_catalog.pg_attribute ref_col
                ON ref_col.attrelid = con.confrelid AND ref_col.attnum = cols.ref_attnum
            WHERE con.contype = 'f'
                AND src_ns.nspname = '\(schemaLiteral)'
            ORDER BY src_cl.relname, con.conname, cols.ord
            """
        let result = try await execute(query: query)
        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard row.count >= 8,
                  let tableName = row[0].asText,
                  let name = row[1].asText,
                  let column = row[2].asText,
                  let refTable = row[3].asText,
                  let refColumn = row[4].asText
            else { continue }
            let fk = PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[5].asText,
                onDelete: row[6].asText ?? "NO ACTION",
                onUpdate: row[7].asText ?? "NO ACTION"
            )
            grouped[tableName, default: []].append(fk)
        }
        return grouped
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let query = """
            SELECT reltuples::bigint
            FROM pg_class
            WHERE relname = '\(escapeLiteral(table))'
              AND relnamespace = (
                  SELECT oid FROM pg_namespace WHERE nspname = current_schema()
              )
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let value = firstRow[0].asText, let count = Int(value) else { return nil }
        return count >= 0 ? count : nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeLiteral(table)
        let resolvedSchema = schema ?? core.currentSchema
        let schemaLiteral = escapeLiteral(resolvedSchema)
        let quotedTable = quoteIdentifier(table)
        let caps = versionedCapabilities

        let identityClause: String = caps.hasIdentityColumns ? """
                CASE
                  WHEN a.attidentity = 'a' THEN ' GENERATED ALWAYS AS IDENTITY'
                  WHEN a.attidentity = 'd' THEN ' GENERATED BY DEFAULT AS IDENTITY'
                  ELSE ''
                END ||
            """ : ""

        let generatedClause: String = caps.hasGeneratedColumns ? """
                CASE
                  WHEN a.attgenerated = 's' THEN ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') STORED'
                  ELSE ''
                END ||
            """ : ""

        let defaultGuard: String
        switch (caps.hasIdentityColumns, caps.hasGeneratedColumns) {
        case (true, true):
            defaultGuard = "AND a.attidentity = '' AND a.attgenerated = ''"
        case (true, false):
            defaultGuard = "AND a.attidentity = ''"
        case (false, true):
            defaultGuard = "AND a.attgenerated = ''"
        case (false, false):
            defaultGuard = ""
        }

        let columnsQuery = """
            SELECT
                quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) ||
                \(identityClause)
                \(generatedClause)
                CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
                CASE
                  WHEN a.atthasdef \(defaultGuard)
                    THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid)
                  ELSE ''
                END
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(schemaLiteral)'
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """

        let constraintsQuery = """
            SELECT
                pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(schemaLiteral)'
              AND con.contype IN ('p', 'u', 'c')
            ORDER BY
              CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 END
            """

        let indexesQuery = """
            SELECT indexdef
            FROM pg_indexes
            WHERE tablename = '\(safeTable)'
              AND schemaname = '\(schemaLiteral)'
              AND indexname NOT IN (
                SELECT conname FROM pg_constraint
                JOIN pg_class ON pg_class.oid = conrelid
                JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
                WHERE pg_class.relname = '\(safeTable)'
                  AND pg_namespace.nspname = '\(schemaLiteral)'
              )
            ORDER BY indexname
            """

        async let columnsResult = execute(query: columnsQuery)
        async let constraintsResult = execute(query: constraintsQuery)
        async let indexesResult = execute(query: indexesQuery)

        let (cols, cons, idxs) = try await (columnsResult, constraintsResult, indexesResult)

        let columnDefs = cols.rows.compactMap { $0[0].asText }
        guard !columnDefs.isEmpty else {
            throw LibPQPluginError(message: "Failed to fetch DDL for table '\(table)'", sqlState: nil, detail: nil)
        }

        let constraints = cons.rows.compactMap { $0[0].asText }
        var parts = columnDefs
        parts.append(contentsOf: constraints)

        let quotedSchema = quoteIdentifier(resolvedSchema)
        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        let indexDefs = idxs.rows.compactMap { $0[0].asText }
        if indexDefs.isEmpty { return ddl }
        return ddl + "\n\n" + indexDefs.joined(separator: ";\n") + ";"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT 'CREATE OR REPLACE VIEW ' || quote_ident(schemaname) || '.' || quote_ident(viewname) || ' AS ' || E'\\n' || definition AS ddl
            FROM pg_views
            WHERE viewname = '\(escapeLiteral(view))'
              AND schemaname = '\(schemaLiteral)'
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let ddl = firstRow[0].asText else {
            throw LibPQPluginError(message: "Failed to fetch definition for view '\(view)'", sqlState: nil, detail: nil)
        }
        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT
                pg_total_relation_size(c.oid) AS total_size,
                pg_table_size(c.oid) AS data_size,
                pg_indexes_size(c.oid) AS index_size,
                c.reltuples::bigint AS row_count,
                obj_description(c.oid, 'pg_class') AS comment
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(escapeLiteral(table))'
              AND n.nspname = '\(schemaLiteral)'
            """
        let result = try await execute(query: query)
        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }

        let totalSize = !row.isEmpty ? Int64(row[0].asText ?? "0") : nil
        let dataSize = row.count > 1 ? Int64(row[1].asText ?? "0") : nil
        let indexSize = row.count > 2 ? Int64(row[2].asText ?? "0") : nil
        let rowCount = row.count > 3 ? Int64(row[3].asText ?? "0") : nil
        let comment = row.count > 4 ? row[4].asText : nil

        return PluginTableMetadata(
            tableName: table,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            rowCount: rowCount,
            comment: comment?.isEmpty == true ? nil : comment,
            engine: "PostgreSQL"
        )
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname")
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: PostgreSQLSchemaQueries.listSchemas)
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let escapedDbLiteral = escapeLiteral(database)
        let query = """
            SELECT
                (SELECT COUNT(*)
                 FROM information_schema.tables t
                 WHERE t.table_catalog = '\(escapedDbLiteral)'
                   AND t.table_schema NOT LIKE 'pg!_%' ESCAPE '!'
                   AND t.table_schema <> 'information_schema'
                   AND NOT EXISTS (
                         SELECT 1
                         FROM pg_catalog.pg_inherits i
                         JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                         JOIN pg_catalog.pg_class child ON child.oid = i.inhrelid
                         JOIN pg_catalog.pg_namespace cn ON cn.oid = child.relnamespace
                         WHERE cn.nspname = t.table_schema
                           AND child.relname = t.table_name
                           AND parent.relkind IN ('p', 'I'))),
                pg_database_size('\(escapedDbLiteral)')
        """
        let result = try await execute(query: query)
        let row = result.rows.first
        let tableCount = Int(row?[0].asText ?? "0") ?? 0
        let sizeBytes = Int64(row?[1].asText ?? "0") ?? 0

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: PostgreSQLSystemDatabases.postgreSQL.contains(database)
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let query = """
            SELECT d.datname, pg_database_size(d.datname)
            FROM pg_database d
            WHERE d.datistemplate = false
            ORDER BY d.datname
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginDatabaseMetadata? in
            guard let dbName = row[0].asText else { return nil }
            let sizeBytes = Int64(row[1].asText ?? "0") ?? 0
            return PluginDatabaseMetadata(
                name: dbName,
                sizeBytes: sizeBytes,
                isSystemDatabase: PostgreSQLSystemDatabases.postgreSQL.contains(dbName)
            )
        }
    }

    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])] {
        let safeTable = escapeLiteral(table)
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT DISTINCT t.typname,
                   array_agg(e.enumlabel ORDER BY e.enumsortorder)
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            JOIN pg_enum e ON e.enumtypid = t.oid
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(schemaLiteral)'
              AND a.attnum > 0
              AND NOT a.attisdropped
            GROUP BY t.typname
            ORDER BY t.typname
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> (name: String, labels: [String])? in
            guard let typeName = row[0].asText, let labelsStr = row[1].asText else { return nil }
            let labels = labelsStr
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")
            return (name: typeName, labels: labels)
        }
    }

    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        guard includesSequencesCatalog() else { return [] }
        let safeTable = escapeLiteral(table)
        let schemaName = schema ?? core.currentSchema
        let schemaLiteral = escapeLiteral(schemaName)
        let query = """
            SELECT s.sequencename,
                   s.start_value,
                   s.min_value,
                   s.max_value,
                   s.increment_by,
                   s.cycle,
                   s.last_value
            FROM pg_attrdef ad
            JOIN pg_class c ON c.oid = ad.adrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_sequences s ON s.schemaname = n.nspname
                 AND pg_get_expr(ad.adbin, ad.adrelid) LIKE '%' || quote_ident(s.sequencename) || '%'
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(schemaLiteral)'
              AND pg_get_expr(ad.adbin, ad.adrelid) LIKE '%nextval%'
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> (name: String, ddl: String)? in
            guard let seqName = row[0].asText else { return nil }
            let startVal = row[1].asText ?? "1"
            let minVal = row[2].asText ?? "1"
            let maxVal = row[3].asText ?? "9223372036854775807"
            let incrementBy = row[4].asText ?? "1"
            let cycle = row[5].asText == "t" ? " CYCLE" : ""
            let lastValue = row.count > 6 ? row[6].asText : nil
            let quotedSeqName = quoteIdentifier(seqName)
            let escapedSeqForLiteral = escapeStringLiteral(seqName)
            var ddl = "CREATE SEQUENCE \(quotedSeqName) INCREMENT BY \(incrementBy)"
                + " MINVALUE \(minVal) MAXVALUE \(maxVal)"
                + " START WITH \(startVal)\(cycle);"
            /// Unqualified, so it names the sequence the line above created rather than the one it
            /// was read from. `setval` takes a `regclass`, which resolves through `search_path`, and
            /// the `CREATE SEQUENCE` beside it is already schema-relative. Spelling the source's own
            /// schema here made the pair disagree: run against another schema it repositioned the
            /// original sequence, and against another database it named one that was not there.
            if let last = lastValue, !last.isEmpty, Int64(last) != nil {
                ddl += "\nSELECT pg_catalog.setval('\"\(escapedSeqForLiteral)\"', \(last), true);"
            }
            return (name: seqName, ddl: ddl)
        }
    }

    /// Every sequence in the schema, including the ones no column defaults from.
    ///
    /// `fetchDependentSequences` answers only those a table's `nextval` default reaches, which is
    /// what a table dump needs. A sequence a routine or the application advances by hand belongs to
    /// nothing, so it is invisible to that query and a dump built only from it restores a database
    /// whose sequence is gone.
    func fetchSequences(schema: String?) async throws -> [PluginSequenceInfo] {
        guard includesSequencesCatalog() else { return [] }
        let schemaName = schema ?? core.currentSchema
        let schemaLiteral = escapeLiteral(schemaName)
        let query = """
            SELECT s.sequencename,
                   s.start_value,
                   s.min_value,
                   s.max_value,
                   s.increment_by,
                   s.cycle,
                   s.last_value,
                   d.refobjid IS NOT NULL AS owned
            FROM pg_sequences s
            JOIN pg_class c ON c.relname = s.sequencename
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = s.schemaname
            LEFT JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'a'
            WHERE s.schemaname = '\(schemaLiteral)'
            ORDER BY s.sequencename
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginSequenceInfo? in
            guard let name = row[0].asText else { return nil }
            let start = row[1].asText ?? "1"
            let minValue = row[2].asText ?? "1"
            let maxValue = row[3].asText ?? "9223372036854775807"
            let increment = row[4].asText ?? "1"
            let cycle = row[5].asText == "t" ? " CYCLE" : ""
            let lastValue = row.count > 6 ? row[6].asText : nil
            let quoted = quoteIdentifier(name)
            var ddl = "CREATE SEQUENCE \(quoted) INCREMENT BY \(increment)"
                + " MINVALUE \(minValue) MAXVALUE \(maxValue)"
                + " START WITH \(start)\(cycle);"
            if let last = lastValue, !last.isEmpty, Int64(last) != nil {
                ddl += "\nSELECT pg_catalog.setval('\"\(escapeStringLiteral(name))\"', \(last), true);"
            }
            return PluginSequenceInfo(name: name, ddl: ddl, schema: schemaName)
        }
    }

    private static let supportedEncodings: [String] = [
        "UTF8", "LATIN1", "SQL_ASCII", "WIN1252", "EUC_JP",
        "EUC_KR", "ISO_8859_5", "KOI8R", "SJIS", "BIG5", "GBK"
    ]

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        let supportsProvider = versionedCapabilities.hasDatabaseICULocale

        async let templateDefaultsTask = fetchTemplate1Defaults()
        async let collationsTask = fetchCollations()
        let templateDefaults = await templateDefaultsTask
        let collations = await collationsTask
        let serverCollate = templateDefaults?.collate
        let serverIcuLocale = templateDefaults?.iculocale
        let libcCollations = collations.libc
        let icuCollations = collations.icu

        let encodingOptions = Self.supportedEncodings.map {
            PluginCreateDatabaseFormSpec.Option(value: $0, label: $0)
        }

        var fields: [PluginCreateDatabaseFormSpec.Field] = [
            PluginCreateDatabaseFormSpec.Field(
                id: "encoding",
                label: String(localized: "Encoding"),
                kind: .picker(options: encodingOptions, defaultValue: "UTF8")
            )
        ]

        if supportsProvider {
            let providerOptions: [PluginCreateDatabaseFormSpec.Option] = [
                PluginCreateDatabaseFormSpec.Option(value: "libc", label: "libc"),
                PluginCreateDatabaseFormSpec.Option(value: "icu", label: "icu")
            ]
            let defaultProvider = templateDefaults?.provider == "i" ? "icu" : "libc"
            fields.append(PluginCreateDatabaseFormSpec.Field(
                id: "provider",
                label: String(localized: "Locale Provider"),
                kind: .picker(options: providerOptions, defaultValue: defaultProvider)
            ))
        }

        let serverDefaultSubtitle = String(localized: "(server default)")
        let libcOptions: [PluginCreateDatabaseFormSpec.Option] = libcCollations.map { name in
            PluginCreateDatabaseFormSpec.Option(
                value: name,
                label: name,
                subtitle: name == serverCollate ? serverDefaultSubtitle : nil
            )
        }

        fields.append(PluginCreateDatabaseFormSpec.Field(
            id: "collation",
            label: String(localized: "Collation"),
            kind: .searchable(options: libcOptions, defaultValue: serverCollate),
            visibleWhen: supportsProvider
                ? PluginCreateDatabaseFormSpec.Visibility(fieldId: "provider", equals: "libc")
                : nil
        ))

        if supportsProvider {
            let icuOptions: [PluginCreateDatabaseFormSpec.Option] = icuCollations.map { name in
                PluginCreateDatabaseFormSpec.Option(
                    value: name,
                    label: name,
                    subtitle: name == serverIcuLocale ? serverDefaultSubtitle : nil
                )
            }
            fields.append(PluginCreateDatabaseFormSpec.Field(
                id: "icu_locale",
                label: String(localized: "ICU Locale"),
                kind: .searchable(options: icuOptions, defaultValue: serverIcuLocale),
                visibleWhen: PluginCreateDatabaseFormSpec.Visibility(fieldId: "provider", equals: "icu")
            ))
        }

        return PluginCreateDatabaseFormSpec(fields: fields)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let quotedName = quoteIdentifier(request.name)

        guard let encoding = request.values["encoding"] else {
            throw LibPQPluginError(
                message: String(localized: "Encoding is required"),
                sqlState: nil,
                detail: nil
            )
        }
        guard Self.supportedEncodings.contains(encoding) else {
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid encoding: %@"), encoding),
                sqlState: nil,
                detail: nil
            )
        }

        var sql = "CREATE DATABASE \(quotedName) ENCODING '\(encoding)'"

        let supportsProvider = versionedCapabilities.hasDatabaseICULocale
        let provider = supportsProvider ? (request.values["provider"] ?? "libc") : "libc"

        switch provider {
        case "libc":
            guard let collation = request.values["collation"], !collation.isEmpty else {
                throw LibPQPluginError(
                    message: String(localized: "Collation is required"),
                    sqlState: nil,
                    detail: nil
                )
            }
            async let allowedCollationsTask = fetchCollations().libc
            async let templateDefaultsTask = fetchTemplate1Defaults()
            let allowedCollations = await allowedCollationsTask
            guard allowedCollations.contains(collation) else {
                throw LibPQPluginError(
                    message: String(format: String(localized: "Invalid collation: %@"), collation),
                    sqlState: nil,
                    detail: nil
                )
            }
            let escapedCollation = escapeLiteral(collation)
            sql += " LC_COLLATE '\(escapedCollation)' LC_CTYPE '\(escapedCollation)'"

            guard let templateDefaults = await templateDefaultsTask else {
                throw LibPQPluginError(
                    message: String(localized: "Failed to read template1 collation defaults"),
                    sqlState: nil,
                    detail: nil
                )
            }
            if templateDefaults.collate != collation {
                sql += " TEMPLATE template0"
            }

        case "icu":
            guard supportsProvider else {
                throw LibPQPluginError(
                    message: String(localized: "ICU provider requires PostgreSQL 15 or newer"),
                    sqlState: nil,
                    detail: nil
                )
            }
            guard let icuLocale = request.values["icu_locale"], !icuLocale.isEmpty else {
                throw LibPQPluginError(
                    message: String(localized: "ICU locale is required"),
                    sqlState: nil,
                    detail: nil
                )
            }
            let allowedIcu = await fetchCollations().icu
            guard allowedIcu.contains(icuLocale) else {
                throw LibPQPluginError(
                    message: String(format: String(localized: "Invalid ICU locale: %@"), icuLocale),
                    sqlState: nil,
                    detail: nil
                )
            }
            let escapedIcu = escapeLiteral(icuLocale)
            if versionedCapabilities.hasModernICUSyntax {
                sql += " LOCALE_PROVIDER 'icu' LOCALE '\(escapedIcu)' TEMPLATE template0"
            } else {
                sql += " LOCALE_PROVIDER 'icu' ICU_LOCALE '\(escapedIcu)' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0"
            }

        default:
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid locale provider: %@"), provider),
                sqlState: nil,
                detail: nil
            )
        }

        _ = try await execute(query: sql)
    }

    func dropDatabase(name: String) async throws {
        _ = try await execute(query: "DROP DATABASE \(quoteIdentifier(name))")
    }

    func dropSchema(name: String) async throws {
        _ = try await execute(query: "DROP SCHEMA \(quoteIdentifier(name)) CASCADE")
    }

    private struct Template1Defaults {
        let collate: String
        let ctype: String
        let provider: String?
        let iculocale: String?
    }

    private func fetchTemplate1Defaults() async -> Template1Defaults? {
        let caps = versionedCapabilities
        let selectColumns: String
        if caps.hasDatabaseLocale {
            selectColumns = "datcollate, datctype, datlocprovider, datlocale"
        } else if caps.hasDatabaseICULocale {
            selectColumns = "datcollate, datctype, datlocprovider, daticulocale"
        } else {
            selectColumns = "datcollate, datctype, NULL, NULL"
        }
        do {
            let result = try await execute(
                query: "SELECT \(selectColumns) FROM pg_database WHERE datname = 'template1'"
            )
            guard let row = result.rows.first,
                  row.count >= 4,
                  let collate = row[0].asText,
                  let ctype = row[1].asText else {
                return nil
            }
            return Template1Defaults(
                collate: collate,
                ctype: ctype,
                provider: row[2].asText,
                iculocale: row[3].asText
            )
        } catch {
            Self.logger.error(
                "Failed to read template1 defaults: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func fetchCollations() async -> (libc: [String], icu: [String]) {
        do {
            let result = try await execute(
                query: "SELECT collname, collprovider FROM pg_collation WHERE collprovider IN ('b', 'c', 'i') ORDER BY collname"
            )
            var libc: [String] = []
            var icu: [String] = []
            for row in result.rows {
                guard row.count >= 2, let name = row[0].asText, let provider = row[1].asText else { continue }
                switch provider {
                case "b", "c":
                    libc.append(name)
                case "i":
                    icu.append(name)
                default:
                    continue
                }
            }
            return (libc: libc, icu: icu)
        } catch {
            Self.logger.error(
                "Failed to read pg_collation: \(error.localizedDescription, privacy: .public)"
            )
            return (libc: [], icu: [])
        }
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        let s = schema ?? currentSchema ?? "public"
        return """
        SELECT
            schemaname as schema,
            relname as name,
            'TABLE' as kind,
            n_live_tup as estimated_rows,
            pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
            pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as data_size,
            pg_size_pretty(pg_indexes_size(schemaname||'.'||relname)) as index_size,
            obj_description((schemaname||'.'||relname)::regclass) as comment
        FROM pg_stat_user_tables
        WHERE schemaname = '\(s)'
        ORDER BY relname
        """
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let schema = core.currentSchema
        let qualifiedTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(definition.tableName))"
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { pgColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(pgForeignKeyDefinition(fk))
        }

        var sql = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        var indexStatements: [String] = []
        for index in definition.indexes {
            indexStatements.append(pgIndexDefinition(index, qualifiedTable: qualifiedTable))
        }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }

        return sql
    }

    private func pgColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        var dataType = col.dataType
        if col.autoIncrement {
            let upper = dataType.uppercased()
            if upper == "BIGINT" || upper == "INT8" {
                dataType = "BIGSERIAL"
            } else {
                dataType = "SERIAL"
            }
        }

        var def = "\(quoteIdentifier(col.name)) \(dataType)"
        if let expression = col.generationExpression?.nilIfEmpty {
            def += " GENERATED ALWAYS AS (\(expression)) \(pgGenerationKeyword(col.generationKind))"
            if !col.isNullable { def += " NOT NULL" }
            // PostgreSQL allows a primary key on a generated column, and the caller relies on the
            // inline key being emitted here: returning early without it created no key at all.
            if inlinePK && col.isPrimaryKey { def += " PRIMARY KEY" }
            return def
        }
        if !col.autoIncrement {
            if col.isNullable {
                def += " NULL"
            } else {
                def += " NOT NULL"
            }
        }
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(pgDefaultValue(defaultValue))"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    /// PostgreSQL 17 added ALTER COLUMN ... SET EXPRESSION AS, which rewrites the column in place.
    /// Nothing else is expressible: making a plain column generated, or a generated one plain, needs
    /// the column dropped and re-added, so those return nil and the operation is refused rather than
    /// silently applying the rest of the edit.
    private func pgGenerationChangeSQL(
        qt: String,
        colName: String,
        old: PluginColumnDefinition,
        new: PluginColumnDefinition
    ) -> String? {
        let oldExpression = old.generationExpression?.nilIfEmpty
        let newExpression = new.generationExpression?.nilIfEmpty
        guard oldExpression != newExpression || old.generationKind != new.generationKind else { return nil }
        guard let newExpression, oldExpression != nil else { return nil }
        guard versionedCapabilities.hasSetGeneratedExpression else { return nil }
        return "ALTER TABLE \(qt) ALTER COLUMN \(colName) SET EXPRESSION AS (\(newExpression))"
    }

    /// Never emitted bare: PostgreSQL 17 and earlier reject VIRTUAL outright and require STORED,
    /// while 18 made VIRTUAL the default, so the keyword has to be explicit either way.
    private func pgGenerationKeyword(_ kind: GenerationKind?) -> String {
        guard versionedCapabilities.hasVirtualGeneratedColumns else { return "STORED" }
        return (kind ?? .virtual).rawValue
    }

    private func pgDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "TRUE" || upper == "FALSE"
            || upper == "CURRENT_TIMESTAMP" || upper == "NOW()"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil
            || upper.hasSuffix("::REGCLASS") {
            return value
        }
        return "'\(escapeLiteral(value))'"
    }

    private func pgIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        var def = "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable)"
        if let type = index.indexType?.uppercased(),
           ["BTREE", "HASH", "GIN", "GIST", "BRIN"].contains(type) {
            def += " USING \(type.lowercased())"
        }
        def += " (\(cols))"
        if let whereClause = index.whereClause, !whereClause.isEmpty {
            def += " WHERE \(whereClause)"
        }
        return def
    }

    private func pgForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refTable: String
        if let schema = fk.referencedSchema, !schema.isEmpty {
            refTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(fk.referencedTable))"
        } else {
            refTable = quoteIdentifier(fk.referencedTable)
        }
        var def = "CONSTRAINT \(quoteIdentifier(fk.name)) FOREIGN KEY (\(cols)) REFERENCES \(refTable) (\(refCols))"
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        pgColumnDefinition(column, inlinePK: false)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        let qualifiedTable = tableName.map { quoteIdentifier($0) } ?? "\"table\""
        return pgIndexDefinition(index, qualifiedTable: qualifiedTable)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        pgForeignKeyDefinition(fk)
    }

    // MARK: - ALTER TABLE DDL

    private func qualifiedTableName(_ table: String) -> String {
        "\(quoteIdentifier(core.currentSchema)).\(quoteIdentifier(table))"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        let qt = qualifiedTableName(table)
        let colDef = pgColumnDefinition(column, inlinePK: false)
        return "ALTER TABLE \(qt) ADD COLUMN \(colDef)"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = qualifiedTableName(table)
        var stmts: [String] = []

        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(qt) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }

        let colName = quoteIdentifier(newColumn.name)

        if oldColumn.dataType.uppercased() != newColumn.dataType.uppercased() {
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) TYPE \(newColumn.dataType)")
        }

        if oldColumn.isNullable != newColumn.isNullable {
            let clause = newColumn.isNullable ? "DROP NOT NULL" : "SET NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(clause)")
        }

        if oldColumn.defaultValue != newColumn.defaultValue {
            if let defaultValue = newColumn.defaultValue {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) SET DEFAULT \(pgDefaultValue(defaultValue))")
            } else {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) DROP DEFAULT")
            }
        }

        if let generationStatement = pgGenerationChangeSQL(qt: qt, colName: colName, old: oldColumn, new: newColumn) {
            stmts.append(generationStatement)
        }

        if let newComment = newColumn.comment, !newComment.isEmpty, newColumn.comment != oldColumn.comment {
            stmts.append("COMMENT ON COLUMN \(qt).\(colName) IS '\(escapeLiteral(newComment))'")
        } else if oldColumn.comment != nil && (newColumn.comment == nil || newColumn.comment?.isEmpty == true) {
            stmts.append("COMMENT ON COLUMN \(qt).\(colName) IS NULL")
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        pgIndexDefinition(index, qualifiedTable: qualifiedTableName(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(core.currentSchema)).\(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) ADD \(pgForeignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !constraint.name.isEmpty else { return nil }
        return "ALTER TABLE \(qualifiedTableName(table)) ADD CONSTRAINT "
            + "\(quoteIdentifier(constraint.name)) CHECK (\(expression))"
    }

    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        guard !constraintName.isEmpty else { return nil }
        return "ALTER TABLE \(qualifiedTableName(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateRenameCheckConstraintSQL(table: String, from oldName: String, to newName: String) -> String? {
        guard !oldName.isEmpty, !newName.isEmpty else { return nil }
        return "ALTER TABLE \(qualifiedTableName(table)) RENAME CONSTRAINT "
            + "\(quoteIdentifier(oldName)) TO \(quoteIdentifier(newName))"
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        let qt = qualifiedTableName(table)
        var stmts: [String] = []
        if !oldColumns.isEmpty {
            let name = constraintName.map { quoteIdentifier($0) } ?? "/* unknown constraint */"
            stmts.append("ALTER TABLE \(qt) DROP CONSTRAINT \(name)")
        }
        if !newColumns.isEmpty {
            let cols = newColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
            stmts.append("ALTER TABLE \(qt) ADD PRIMARY KEY (\(cols))")
        }
        return stmts.isEmpty ? nil : stmts
    }
}
