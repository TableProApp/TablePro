//
//  PostgreSQLForeignKeyQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum PostgreSQLForeignKeyQueries {
    static func foreignKeyList(schema: String, table: String?, capabilities: PostgreSQLCapabilities) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let tablePredicate = table.map { "\n                AND src.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
        let clonePredicate = capabilities.hasConstraintParent ? """

                    AND NOT EXISTS (
                        SELECT 1
                        FROM pg_catalog.pg_constraint parent
                        WHERE parent.oid = c.conparentid
                            AND parent.conrelid = c.conrelid
                    )
            """ : ""
        return """
            SELECT
                src_cl.relname AS table_name,
                con.conname,
                src_col.attname,
                ref_cl.relname AS referenced_table,
                ref_col.attname AS referenced_column,
                ref_ns.nspname AS referenced_schema,
                \(referentialAction("con.confdeltype")) AS delete_rule,
                \(referentialAction("con.confupdtype")) AS update_rule
            FROM (
                SELECT c.conname, c.conrelid, c.confrelid, c.confdeltype, c.confupdtype, c.conkey, c.confkey,
                       pg_catalog.generate_subscripts(c.conkey, 1) AS ord
                FROM pg_catalog.pg_constraint c
                JOIN pg_catalog.pg_class src ON src.oid = c.conrelid
                JOIN pg_catalog.pg_namespace ns ON ns.oid = src.relnamespace
                WHERE c.contype = 'f'
                    AND ns.nspname = \(schemaLiteral)\(tablePredicate)\(clonePredicate)
            ) con
            JOIN pg_catalog.pg_class src_cl ON src_cl.oid = con.conrelid
            JOIN pg_catalog.pg_class ref_cl ON ref_cl.oid = con.confrelid
            JOIN pg_catalog.pg_namespace ref_ns ON ref_ns.oid = ref_cl.relnamespace
            JOIN pg_catalog.pg_attribute src_col
                ON src_col.attrelid = con.conrelid AND src_col.attnum = con.conkey[con.ord]
            JOIN pg_catalog.pg_attribute ref_col
                ON ref_col.attrelid = con.confrelid AND ref_col.attnum = con.confkey[con.ord]
            ORDER BY src_cl.relname, con.conname, con.ord
            """
    }

    private static func referentialAction(_ column: String) -> String {
        """
        CASE \(column)
                    WHEN 'c' THEN 'CASCADE'
                    WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT'
                    WHEN 'r' THEN 'RESTRICT'
                    ELSE 'NO ACTION'
                END
        """
    }
}

struct PostgreSQLForeignKeyRow {
    let table: String
    let foreignKey: PluginForeignKeyInfo

    init?(_ row: [PluginCellValue]) {
        guard row.count >= 8,
              let table = row[0].asText,
              let name = row[1].asText,
              let column = row[2].asText,
              let referencedTable = row[3].asText,
              let referencedColumn = row[4].asText
        else { return nil }
        self.table = table
        self.foreignKey = PluginForeignKeyInfo(
            name: name,
            column: column,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn,
            referencedSchema: row[5].asText,
            onDelete: row[6].asText ?? "NO ACTION",
            onUpdate: row[7].asText ?? "NO ACTION"
        )
    }
}
