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

        let qualified = "\(quoteIdentifier(resolvedSchema)).\(quoteIdentifier(table))"
        let staging = "\(quoteIdentifier(resolvedSchema)).\(quoteIdentifier("\(table)_tablepro_reorder"))"
        let copyList = parts.copyableColumns.map { quoteIdentifier($0) }.joined(separator: ", ")

        let body = desiredOrder.compactMap { parts.columnDefinitions[$0] }

        /// The order here is the whole difficulty, and every step of it was measured against
        /// PostgreSQL 17. The old table is renamed rather than dropped, so a foreign key in another
        /// table keeps pointing at real rows while the copy runs. But a rename moves nothing else:
        /// the staging table still owns every index name and every constraint name the original
        /// had, and both live in the schema rather than on the table. Declaring the constraints
        /// inside the `CREATE TABLE` therefore silently renames them, which shipped as `x_pkey1`,
        /// `x_a_b_key1` and `x_c_check1`; creating an index before the staging table goes fails
        /// outright with "relation already exists". So nothing that carries a name is created until
        /// the staging table is dropped, and the staging table cannot be dropped until every
        /// inbound foreign key has let go of it.
        var statements = ["BEGIN"]
        statements.append("ALTER TABLE \(qualified) RENAME TO \(quoteIdentifier("\(table)_tablepro_reorder"))")
        statements.append("CREATE TABLE \(qualified) (\n  " + body.joined(separator: ",\n  ") + "\n)")
        statements.append("INSERT INTO \(qualified) (\(copyList)) SELECT \(copyList) FROM \(staging)")
        statements.append(contentsOf: parts.identityResets(qualified: qualified, quote: quoteIdentifier))
        statements.append(contentsOf: parts.inboundForeignKeyDrops)
        statements.append("DROP TABLE \(staging)")
        statements.append(contentsOf: parts.tableConstraints.map { "ALTER TABLE \(qualified) ADD \($0)" })
        statements.append(contentsOf: parts.outboundForeignKeys.map { "ALTER TABLE \(qualified) ADD \($0)" })
        statements.append(contentsOf: parts.inboundForeignKeyAdds)
        statements.append(contentsOf: parts.indexes)
        statements.append(contentsOf: parts.triggers)
        statements.append(contentsOf: parts.comments)
        statements.append("COMMIT")

        return PluginColumnReorderPlan(
            statements: statements,
            rollbackStatements: ["ROLLBACK"],
            cost: .tableRebuild,
            caveats: [
                String(localized: "Grants, row-level security policies, publications, extended statistics, partitioning and table inheritance are not carried over."),
                String(localized: "A column collation that differs from its type default is not reproduced."),
                String(localized: "A sequence owned by a serial column is dropped with the old table; an identity column is reset to its current maximum.")
            ],
            isRunnable: false
        )
    }

    private struct RebuildParts {
        var columnNames: [String] = []
        var columnDefinitions: [String: String] = [:]
        var copyableColumns: [String] = []
        var identityColumns: [String] = []
        var tableConstraints: [String] = []
        var outboundForeignKeys: [String] = []
        var inboundForeignKeyDrops: [String] = []
        var inboundForeignKeyAdds: [String] = []
        var indexes: [String] = []
        var triggers: [String] = []
        var comments: [String] = []

        /// A new identity column starts its sequence at one, so it is wound forward to the rows the
        /// copy just wrote. Without this the next insert collides with an existing key.
        func identityResets(qualified: String, quote: (String) -> String) -> [String] {
            identityColumns.map { column in
                let quoted = quote(column)
                return """
                    SELECT setval(
                      pg_get_serial_sequence('\(qualified)', '\(column.replacingOccurrences(of: "'", with: "''"))'),
                      GREATEST(COALESCE((SELECT MAX(\(quoted)) FROM \(qualified)), 0), 1),
                      true
                    )
                    """
            }
        }
    }

    private func fetchRebuildParts(table: String, schema: String) async throws -> RebuildParts {
        let safeTable = escapeLiteral(table)
        let safeSchema = escapeLiteral(schema)
        let caps = versionedCapabilities
        var parts = RebuildParts()

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
              ELSE ''
            END ||
            """ : ""
        let defaultGuard = [
            caps.hasIdentityColumns ? "AND a.attidentity = ''" : "",
            caps.hasGeneratedColumns ? "AND a.attgenerated = ''" : ""
        ].filter { !$0.isEmpty }.joined(separator: " ")
        let identityFlag = caps.hasIdentityColumns ? "a.attidentity <> ''" : "false"
        let generatedFlag = caps.hasGeneratedColumns ? "a.attgenerated <> ''" : "false"

        let columnRows = try await execute(query: """
            SELECT
                a.attname,
                quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) ||
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
            WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)'
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """).rows

        for row in columnRows {
            guard let name = row[safe: 0]?.asText, let definition = row[safe: 1]?.asText else { continue }
            parts.columnNames.append(name)
            parts.columnDefinitions[name] = definition
            if isTrue(row[safe: 2]?.asText) { parts.identityColumns.append(name) }
            /// A generated column is computed, never written, so `INSERT` refuses it by name.
            if !isTrue(row[safe: 3]?.asText) { parts.copyableColumns.append(name) }
        }

        /// Named, and added after the staging table is gone. Declared inline instead, PostgreSQL
        /// finds the name already taken and quietly picks another.
        parts.tableConstraints = try await textRows("""
            SELECT 'CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)'
              AND con.contype IN ('p', 'u', 'c')
            ORDER BY CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 ELSE 2 END, con.conname
            """)

        parts.outboundForeignKeys = try await textRows("""
            SELECT 'CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)' AND con.contype = 'f'
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
            WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)' AND con.contype = 'f'
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
        parts.indexes = try await textRows("""
            SELECT indexdef FROM pg_indexes
            WHERE tablename = '\(safeTable)' AND schemaname = '\(safeSchema)'
              AND indexname NOT IN (
                SELECT con.conname FROM pg_constraint con
                JOIN pg_class c ON c.oid = con.conrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)'
              )
            ORDER BY indexname
            """)

        parts.triggers = try await textRows("""
            SELECT pg_get_triggerdef(t.oid, true)
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)' AND NOT t.tgisinternal
            ORDER BY t.tgname
            """)

        parts.comments = try await textRows("""
            SELECT 'COMMENT ON TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
                   || ' IS ' || quote_literal(obj_description(c.oid, 'pg_class'))
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)'
              AND obj_description(c.oid, 'pg_class') IS NOT NULL
            UNION ALL
            SELECT 'COMMENT ON COLUMN ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
                   || '.' || quote_ident(a.attname)
                   || ' IS ' || quote_literal(col_description(c.oid, a.attnum))
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)' AND n.nspname = '\(safeSchema)'
              AND a.attnum > 0 AND NOT a.attisdropped
              AND col_description(c.oid, a.attnum) IS NOT NULL
            """)

        return parts
    }

    private func textRows(_ query: String) async throws -> [String] {
        try await execute(query: query).rows.compactMap { $0[safe: 0]?.asText }
    }

    /// libpq reports a boolean as `t` on the text protocol and the driver may hand it back either
    /// way, so both spellings are accepted rather than one being assumed.
    private func isTrue(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "t" || value.lowercased() == "true"
    }
}
