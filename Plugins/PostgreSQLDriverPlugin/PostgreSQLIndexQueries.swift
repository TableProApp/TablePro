//
//  PostgreSQLIndexQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum PostgreSQLIndexQueries {
    static func indexList(schema: String, table: String?) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let tablePredicate = table.map { " AND t.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
        return """
            SELECT
                t.relname AS table_name,
                i.relname AS index_name,
                ARRAY_AGG(a.attname ORDER BY (
                    SELECT min(k)
                    FROM pg_catalog.generate_subscripts(ix.indkey, 1) AS k
                    WHERE ix.indkey[k] = a.attnum
                ))::text AS columns,
                ix.indisunique AS is_unique,
                ix.indisprimary AS is_primary,
                am.amname AS index_type,
                pg_catalog.pg_get_expr(ix.indpred, ix.indrelid) AS predicate
            FROM pg_catalog.pg_index ix
            JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
            JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_catalog.pg_am am ON am.oid = i.relam
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
            WHERE n.nspname = \(schemaLiteral)\(tablePredicate)
            GROUP BY t.relname, i.relname, ix.indisunique, ix.indisprimary, am.amname, ix.indpred, ix.indrelid
            ORDER BY t.relname, ix.indisprimary DESC, i.relname
            """
    }
}

enum PostgreSQLIndexRow {
    static func index(from row: [PluginCellValue]) -> (table: String, index: PluginIndexInfo)? {
        guard let table = row[safe: 0]?.asText,
              let name = row[safe: 1]?.asText,
              let columnsText = row[safe: 2]?.asText else { return nil }
        let index = PluginIndexInfo(
            name: name,
            columns: PostgreSQLTextArray.values(columnsText),
            isUnique: PostgreSQLCatalogBoolean.isTrue(row[safe: 3]?.asText),
            isPrimary: PostgreSQLCatalogBoolean.isTrue(row[safe: 4]?.asText),
            type: row[safe: 5]?.asText?.uppercased() ?? "BTREE",
            whereClause: row[safe: 6]?.asText
        )
        return (table, index)
    }
}
