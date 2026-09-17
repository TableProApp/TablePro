//
//  PostgreSQLIndexQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProPluginKit

enum PostgreSQLIndexQueries {
    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "IndexQueries")

    /// One row per index, with its key parts in key order.
    ///
    /// A key part is read by position rather than by joining `pg_attribute` on `indkey`. An expression
    /// key stores attribute number 0, which no attribute has, so that join dropped every expression
    /// from the list: `(tenant_id, lower(email))` read as `(tenant_id)` and an index over expressions
    /// alone was missing entirely. It also listed `INCLUDE` columns as key columns, because `indkey`
    /// holds them after the key. `indnkeyatts` separates the two from PostgreSQL 11, the release that
    /// added `INCLUDE`; before it every attribute is a key part.
    ///
    /// An expression is written by `pg_get_indexdef(oid, k, true)` under the session's `search_path`,
    /// the same way `predicate` is, because both are display text. `indexDDLQuery` reads the spelling
    /// that is written back.
    static func indexList(schema: String, table: String?, capabilities: PostgreSQLCapabilities) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let tablePredicate = table.map { " AND t.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
        let keyCount = capabilities.hasCoveringIndexes ? "ix.indnkeyatts" : "ix.indnatts"
        return """
            SELECT
                t.relname AS table_name,
                i.relname AS index_name,
                ARRAY(
                    SELECT CASE
                        WHEN ix.indkey[k.n - 1] = 0 THEN pg_catalog.pg_get_indexdef(ix.indexrelid, k.n, true)
                        ELSE a.attname
                    END
                    FROM pg_catalog.generate_series(1, \(keyCount)) AS k(n)
                    LEFT JOIN pg_catalog.pg_attribute a
                        ON a.attrelid = ix.indrelid AND a.attnum = ix.indkey[k.n - 1]
                    ORDER BY k.n
                )::text AS columns,
                ix.indisunique AS is_unique,
                ix.indisprimary AS is_primary,
                am.amname AS index_type,
                pg_catalog.pg_get_expr(ix.indpred, ix.indrelid) AS predicate,
                ARRAY(
                    SELECT pg_catalog.pg_get_indexdef(ix.indexrelid, k.n, true)
                    FROM pg_catalog.generate_series(1, \(keyCount)) AS k(n)
                    WHERE ix.indkey[k.n - 1] = 0
                    ORDER BY k.n
                )::text AS expressions,
                ARRAY(
                    SELECT a.attname
                    FROM pg_catalog.generate_series(\(keyCount) + 1, ix.indnatts) AS k(n)
                    JOIN pg_catalog.pg_attribute a
                        ON a.attrelid = ix.indrelid AND a.attnum = ix.indkey[k.n - 1]
                    ORDER BY k.n
                )::text AS included_columns
            FROM pg_catalog.pg_index ix
            JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
            JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_catalog.pg_am am ON am.oid = i.relam
            WHERE n.nspname = \(schemaLiteral)\(tablePredicate)
            ORDER BY t.relname, ix.indisprimary DESC, i.relname
            """
    }

    /// The server's own `CREATE INDEX` for each index, cut into the part a copy writes back.
    ///
    /// Run through `executeQualifiedRead`, so every type, operator class and function the definition
    /// names outside `pg_catalog` comes back with its schema. Replayed bare, `gin_trgm_ops`,
    /// `'a'::mood` and `st_isvalid(shape)` each failed under a target `search_path` that is only the
    /// target schema.
    ///
    /// The cut happens on the server, against a prefix built with `quote_ident`, because
    /// `pg_get_indexdef` quotes names with the same `quote_identifier` that `quote_ident` calls. Swift's
    /// quoting differs (it quotes every name), so a prefix built here would never match. The prefix is
    /// what `pg_get_indexdef` writes before the access method: `ONLY` appears for a partitioned index
    /// with no parent, whether or not it was created with it. The suffix is the predicate as
    /// `pg_get_expr` writes it, which is the same deparse with the same flags. When either end fails to
    /// match byte for byte, `method_and_keys` is NULL and the index falls back to its fields. Cutting
    /// at the first ` USING ` or the last ` WHERE ` instead would split an index named
    /// `i ON s.t USING btree (` or a predicate holding the literal `' WHERE '`.
    static func indexDDLQuery(schema: String, table: String?) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let tablePredicate = table.map { " AND t.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
        return """
            SELECT
                d.table_name,
                d.index_name,
                CASE
                    WHEN pg_catalog.length(d.definition) >= pg_catalog.length(d.prefix) + pg_catalog.length(d.suffix)
                        AND pg_catalog.substr(d.definition, 1, pg_catalog.length(d.prefix)) = d.prefix
                        AND pg_catalog.substr(
                            d.definition, pg_catalog.length(d.definition) - pg_catalog.length(d.suffix) + 1
                        ) = d.suffix
                    THEN pg_catalog.substr(
                        d.definition,
                        pg_catalog.length(d.prefix) + 1,
                        pg_catalog.length(d.definition) - pg_catalog.length(d.prefix) - pg_catalog.length(d.suffix)
                    )
                END AS method_and_keys,
                d.predicate
            FROM (
                SELECT
                    t.relname AS table_name,
                    i.relname AS index_name,
                    pg_catalog.pg_get_indexdef(ix.indexrelid) AS definition,
                    'CREATE '
                        || CASE WHEN ix.indisunique THEN 'UNIQUE ' ELSE '' END
                        || 'INDEX ' || pg_catalog.quote_ident(i.relname) || ' ON '
                        || CASE
                            WHEN i.relkind = 'I' AND NOT EXISTS (
                                SELECT 1 FROM pg_catalog.pg_inherits inh WHERE inh.inhrelid = ix.indexrelid
                            ) THEN 'ONLY '
                            ELSE ''
                        END
                        || pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(t.relname) || ' '
                        AS prefix,
                    COALESCE(' WHERE ' || pg_catalog.pg_get_expr(ix.indpred, ix.indrelid), '') AS suffix,
                    pg_catalog.pg_get_expr(ix.indpred, ix.indrelid) AS predicate
                FROM pg_catalog.pg_index ix
                JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
                JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
                JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
                WHERE n.nspname = \(schemaLiteral)\(tablePredicate)
            ) d
            """
    }

    /// Keyed by table, then by index, with exact spellings: PostgreSQL allows quoted `Orders` and
    /// `orders` side by side, so folding case here would hand one table the other's indexes.
    static func indexDDL(rows: [[PluginCellValue]]) -> [String: [String: PostgreSQLCatalogIndexDDL]] {
        var indexes: [String: [String: PostgreSQLCatalogIndexDDL]] = [:]
        for row in rows {
            guard let table = row[safe: 0]?.asText,
                  let index = row[safe: 1]?.asText else { continue }
            let methodAndKeys = row[safe: 2]?.asText?.nilIfEmpty
            if methodAndKeys == nil {
                logger.warning(
                    "pg_get_indexdef for \(table, privacy: .public).\(index, privacy: .public) did not match its prefix or predicate, so the index is written from its fields"
                )
            }
            indexes[table, default: [:]][index] = PostgreSQLCatalogIndexDDL(
                methodAndKeys: methodAndKeys,
                whereClause: row[safe: 3]?.asText?.nilIfEmpty
            )
        }
        return indexes
    }
}

struct PostgreSQLCatalogIndexDDL: Equatable {
    let methodAndKeys: String?
    let whereClause: String?
}

enum PostgreSQLIndexRow {
    static func index(
        from row: [PluginCellValue],
        ddl: [String: [String: PostgreSQLCatalogIndexDDL]]
    ) -> (table: String, index: PluginIndexInfo)? {
        guard let table = row[safe: 0]?.asText,
              let name = row[safe: 1]?.asText,
              let columnsText = row[safe: 2]?.asText else { return nil }
        let spelling = ddl[table]?[name]
        let index = PluginIndexInfo(
            name: name,
            columns: PostgreSQLTextArray.values(columnsText),
            isUnique: PostgreSQLCatalogBoolean.isTrue(row[safe: 3]?.asText),
            isPrimary: PostgreSQLCatalogBoolean.isTrue(row[safe: 4]?.asText),
            type: row[safe: 5]?.asText?.uppercased() ?? "BTREE",
            whereClause: row[safe: 6]?.asText,
            expressions: nonEmptyValues(row[safe: 7]?.asText),
            includedColumns: nonEmptyValues(row[safe: 8]?.asText),
            ddlMethodAndKeys: spelling?.methodAndKeys,
            ddlWhereClause: spelling?.whereClause
        )
        return (table, index)
    }

    private static func nonEmptyValues(_ text: String?) -> [String]? {
        let values = PostgreSQLTextArray.values(text)
        return values.isEmpty ? nil : values
    }
}
