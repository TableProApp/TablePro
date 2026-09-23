//
//  PostgreSQLPluginDriver+ColumnReorder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    /// PostgreSQL stores column order as `pg_attribute.attnum` and offers nothing that changes it,
    /// so the order changes by recreating the table and copying its rows.
    ///
    /// TablePro writes the script and does not run it. The catalog describes the table's columns,
    /// constraints, indexes, triggers and comments, all through server functions that produce
    /// canonical text, but it does not hand back everything a table can carry: the caveats name
    /// what a rebuild leaves behind. Running that behind a button would report success over a lost
    /// grant or a policy that no longer applies, so the script goes to the user instead.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        let resolvedSchema = schema ?? core.currentSchema
        let parts = try await fetchRebuildParts(table: table, schema: resolvedSchema)
        guard !parts.columnDefinitions.isEmpty else { return nil }
        guard parts.columnNames != desiredOrder,
              Set(parts.columnNames) == Set(desiredOrder),
              parts.columnNames.count == desiredOrder.count else { return nil }

        return PluginColumnReorderPlan(
            statements: parts.statements(
                table: table,
                schema: resolvedSchema,
                desiredOrder: desiredOrder,
                quote: quoteIdentifier,
                capabilities: versionedCapabilities
            ),
            isTransactional: true,
            cost: .tableRebuild,
            caveats: parts.caveats,
            isRunnable: false
        )
    }

    private func fetchRebuildParts(table: String, schema: String) async throws -> PostgreSQLTableRebuild {
        let tableLiteral = PostgreSQLObjectQueries.quoteLiteral(table)
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let caps = versionedCapabilities
        var parts = PostgreSQLTableRebuild()

        let columnRows = try await rebuildColumnRows(tableLiteral: tableLiteral, schemaLiteral: schemaLiteral)

        for row in columnRows {
            guard let name = row[safe: 0]?.asText, let definition = row[safe: 1]?.asText else { continue }
            parts.columnNames.append(name)
            parts.columnDefinitions[name] = definition
            if PostgreSQLCatalogBoolean.isTrue(row[safe: 2]?.asText) { parts.identityColumns.append(name) }
            /// A generated column is computed, never written, so `INSERT` refuses it by name.
            if !PostgreSQLCatalogBoolean.isTrue(row[safe: 3]?.asText) { parts.copyableColumns.append(name) }
        }

        /// Named, and added after the staging table is gone. Declared inline instead, PostgreSQL
        /// finds the name already taken and quietly picks another.
        parts.tableConstraints = try await textRows("""
            SELECT 'CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral)
              AND con.contype IN ('p', 'u', 'c', 'x')
            ORDER BY CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 ELSE 2 END, con.conname
            """)

        parts.outboundForeignKeys = try await textRows("""
            SELECT 'CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral) AND con.contype = 'f'
            ORDER BY con.conname
            """)

        /// A key in another table follows the rename, so it now points at the staging table and is
        /// the only thing keeping it alive. Dropping every one is what lets the staging table go;
        /// re-adding them against the rebuilt table happens once its primary key is back.
        let inboundClause = """
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.confrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_class c2 ON c2.oid = con.conrelid
            JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral) AND con.contype = 'f'
              AND con.conrelid <> con.confrelid
            ORDER BY con.conname
            """
        parts.inboundForeignKeyDrops = try await textRows("""
            SELECT 'ALTER TABLE ' || quote_ident(n2.nspname) || '.' || quote_ident(c2.relname)
                   || ' DROP CONSTRAINT ' || quote_ident(con.conname)
            \(inboundClause)
            """)
        parts.inboundForeignKeyAdds = try await textRows("""
            SELECT 'ALTER TABLE ' || quote_ident(n2.nspname) || '.' || quote_ident(c2.relname)
                   || ' ADD CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid, true)
            \(inboundClause)
            """)

        /// The indexes a constraint owns come back with the constraint, so listing them again would
        /// fail on a duplicate name.
        let standaloneIndexes = try await fetchStandaloneIndexes(table: table, schema: schema)
        parts.indexes = standaloneIndexes.definitions
        parts.invalidIndexes = standaloneIndexes.invalidNames

        parts.triggers = try await textRows("""
            SELECT pg_get_triggerdef(t.oid, true)
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral) AND NOT t.tgisinternal
            ORDER BY t.tgname
            """)

        /// `pg_get_triggerdef` writes the definition and nothing about whether the trigger is
        /// firing, so a recreated one comes back ordinarily enabled however it was left. A trigger
        /// the user disabled, or set to fire only on a replica or always, silently starts firing on
        /// writes it was excluded from.
        parts.triggerModes = try await textRows("""
            SELECT 'ALTER TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
                   || CASE t.tgenabled
                        WHEN 'D' THEN ' DISABLE TRIGGER '
                        WHEN 'R' THEN ' ENABLE REPLICA TRIGGER '
                        WHEN 'A' THEN ' ENABLE ALWAYS TRIGGER '
                      END
                   || quote_ident(t.tgname)
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral) AND NOT t.tgisinternal
              AND t.tgenabled <> 'O'
            ORDER BY t.tgname
            """)

        /// A `serial` column, unlike an identity one, owns a sequence the rebuilt table's default
        /// still calls. The server writes the whole statement so no identifier has to be quoted or
        /// escaped here.
        parts.serialSequenceHandovers = try await textRows("""
            SELECT 'ALTER SEQUENCE ' || pg_get_serial_sequence(
                       quote_ident(n.nspname) || '.' || quote_ident(c.relname), a.attname
                   )
                   || ' OWNED BY ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
                   || '.' || quote_ident(a.attname)
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral)
              AND a.attnum > 0 AND NOT a.attisdropped
              AND \(caps.hasIdentityColumns ? "a.attidentity = ''" : "true")
              AND pg_get_serial_sequence(
                    quote_ident(n.nspname) || '.' || quote_ident(c.relname), a.attname
                  ) IS NOT NULL
            ORDER BY a.attnum
            """)

        parts.comments = try await textRows("""
            SELECT 'COMMENT ON TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
                   || ' IS ' || quote_literal(obj_description(c.oid, 'pg_class'))
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral)
              AND obj_description(c.oid, 'pg_class') IS NOT NULL
            UNION ALL
            SELECT 'COMMENT ON COLUMN ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
                   || '.' || quote_ident(a.attname)
                   || ' IS ' || quote_literal(col_description(c.oid, a.attnum))
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral)
              AND a.attnum > 0 AND NOT a.attisdropped
              AND col_description(c.oid, a.attnum) IS NOT NULL
            """)

        parts.dependentViews = try await textRows("""
            SELECT DISTINCT quote_ident(dn.nspname) || '.' || quote_ident(dc.relname)
            FROM pg_depend d
            JOIN pg_rewrite r ON r.oid = d.objid
            JOIN pg_class dc ON dc.oid = r.ev_class
            JOIN pg_namespace dn ON dn.oid = dc.relnamespace
            JOIN pg_class c ON c.oid = d.refobjid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral)
              AND dc.relkind IN ('v', 'm')
              AND dc.oid <> c.oid
            ORDER BY 1
            """)

        return parts
    }

    private func rebuildColumnRows(tableLiteral: String, schemaLiteral: String) async throws -> [[PluginCellValue]] {
        let caps = versionedCapabilities
        let identityClause = caps.hasIdentityColumns ? """
            CASE
              WHEN a.attidentity = 'a' THEN ' GENERATED ALWAYS AS IDENTITY'
              WHEN a.attidentity = 'd' THEN ' GENERATED BY DEFAULT AS IDENTITY'
              ELSE ''
            END ||
            """ : ""
        let generatedClause = caps.hasGeneratedColumns ? """
            CASE
              WHEN a.attgenerated = 's' THEN ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') STORED'
              WHEN a.attgenerated = 'v' THEN ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') VIRTUAL'
              ELSE ''
            END ||
            """ : ""
        let defaultGuard = [
            caps.hasIdentityColumns ? "AND a.attidentity = ''" : "",
            caps.hasGeneratedColumns ? "AND a.attgenerated = ''" : ""
        ].filter { !$0.isEmpty }.joined(separator: " ")
        let identityFlag = caps.hasIdentityColumns ? "a.attidentity <> ''" : "false"
        let generatedFlag = caps.hasGeneratedColumns ? "a.attgenerated <> ''" : "false"

        return try await execute(query: """
            SELECT
                a.attname,
                quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) || \(PostgreSQLSchemaQueries.columnCollateClause) ||
                \(identityClause)
                \(generatedClause)
                CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
                CASE
                  WHEN a.atthasdef \(defaultGuard)
                    THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid)
                  ELSE ''
                END,
                \(identityFlag),
                \(generatedFlag)
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
            WHERE c.relname = \(tableLiteral) AND n.nspname = \(schemaLiteral)
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """).rows
    }

    private func textRows(_ query: String) async throws -> [String] {
        try await execute(query: query).rows.compactMap { $0[safe: 0]?.asText }
    }
}
