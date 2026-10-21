//
//  SQLiteTemporarySchema.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

// A connection's `temp` schema is its own: another connection to the same file sees none of it. SQLite resolves a bare
// name in `temp` before `main`, so a catalog read that looks at `sqlite_master` alone misses a temporary table, or
// answers with the main table it hides.
enum SQLiteTemporarySchema {
    static let tablesQuery = """
        SELECT name, type FROM sqlite_temp_master
        WHERE type IN ('table', 'view')
        AND name NOT GLOB 'sqlite_*'
        ORDER BY name
        """

    // A schema names an attached database, whose catalog holds the object alone: `temp` hides nothing there.
    static func definitionQuery(name: String, types: [String], schema: String?) -> String {
        let literal = SQLiteMasterQueries.escapeLiteral(name)
        let kinds = types.map { "'\($0)'" }.joined(separator: ", ")
        if SQLiteMasterQueries.attachedSchema(schema) != nil {
            return """
                SELECT type, sql FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
                WHERE type IN (\(kinds)) AND name = '\(literal)'
                """
        }
        return """
            SELECT type, sql FROM (
                SELECT type, sql, 0 AS search_order FROM sqlite_temp_master
                WHERE type IN (\(kinds)) AND name = '\(literal)'
                UNION ALL
                SELECT type, sql, 1 AS search_order FROM sqlite_master
                WHERE type IN (\(kinds)) AND name = '\(literal)'
            )
            ORDER BY search_order
            LIMIT 1
            """
    }

    static func indexDefinitionsQuery(table: String, schema: String?) -> String {
        """
        SELECT sql, name FROM (\(objectsOfTable(table, type: "index", schema: schema))) WHERE sql IS NOT NULL
        ORDER BY name
        """
    }

    // The shared `SQLiteIndexCatalog` row shape, with each index's own text read from the table's own schema.
    static func indexesQuery(table: String, schema: String?) -> String {
        guard SQLiteMasterQueries.attachedSchema(schema) == nil else {
            return SQLiteIndexCatalog.indexesQuery(table: table, schema: schema)
        }
        return """
        SELECT il.name, il."unique", il.origin, ix.cid, ix.name, m.sql
        FROM pragma_index_list('\(SQLiteMasterQueries.escapeLiteral(table))') il
        LEFT JOIN pragma_index_xinfo(il.name) ix ON ix.key = 1
        LEFT JOIN (\(objectsOfTable(table, type: "index", schema: nil))) m ON m.name = il.name
        ORDER BY il.seq, ix.seqno
        """
    }

    // The shared `SQLiteMasterQueries.triggerList` row shape. Without a table it lists one schema's triggers.
    static func triggerListQuery(table: String?, schema: String?) -> String {
        guard let table else {
            return SQLiteMasterQueries.triggerList(table: nil, schema: schema, excludeNameGlob: nil)
        }
        return """
        SELECT name, tbl_name, sql FROM (\(objectsOfTable(table, type: "trigger", schema: schema)))
        ORDER BY tbl_name, name
        """
    }

    private static func objectsOfTable(_ table: String, type: String, schema: String?) -> String {
        let literal = SQLiteMasterQueries.escapeLiteral(table)
        if SQLiteMasterQueries.attachedSchema(schema) != nil {
            return """
                SELECT name, tbl_name, sql FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
                WHERE type = '\(type)' AND tbl_name = '\(literal)'
                """
        }
        return objectsOfResolvedTable(literal: literal, type: type)
    }

    private static func objectsOfResolvedTable(literal: String, type: String) -> String {
        let inTemp = "EXISTS (SELECT 1 FROM sqlite_temp_master WHERE type IN ('table', 'view') AND name = '\(literal)')"
        return """
            SELECT name, tbl_name, sql FROM sqlite_temp_master
            WHERE type = '\(type)' AND tbl_name = '\(literal)' AND \(inTemp)
            UNION ALL
            SELECT name, tbl_name, sql FROM sqlite_master
            WHERE type = '\(type)' AND tbl_name = '\(literal)' AND NOT \(inTemp)
            """
    }
}
