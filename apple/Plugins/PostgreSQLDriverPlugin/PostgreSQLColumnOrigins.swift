//
//  PostgreSQLColumnOrigins.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation
import TableProPluginKit

// The server resolves each result column to the relation column it reads through aliases, subqueries and CTEs, and
// reports none for an expression, a set operation or a whole-row reference. Measured on PostgreSQL 17.
enum PostgreSQLColumnOrigins {
    struct Source: Hashable, Sendable {
        let relation: UInt32
        let attribute: Int32
    }

    // A system column has a negative number and a whole-row reference reports 0, so only a positive one is a column.
    static func source(relation: UInt32, attribute: Int32) -> Source? {
        guard relation != 0, attribute > 0 else { return nil }
        return Source(relation: relation, attribute: attribute)
    }

    static func sources(of result: OpaquePointer) -> [Source?] {
        (0..<PQnfields(result)).map { field in
            source(relation: UInt32(PQftable(result, field)), attribute: PQftablecol(result, field))
        }
    }

    static func lookupQuery(for sources: [Source?]) -> String? {
        let relations = Set(sources.compactMap { $0?.relation }).sorted()
        guard !relations.isEmpty else { return nil }
        let list = relations.map(String.init).joined(separator: ",")
        return """
            SELECT a.attrelid, a.attnum, n.nspname, c.relname, a.attname \
            FROM pg_catalog.pg_attribute a \
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid \
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
            WHERE a.attrelid = ANY ('{\(list)}'::pg_catalog.oid[]) AND a.attnum > 0 AND NOT a.attisdropped
            """
    }

    // Only a user table is vouched for. A catalog or system view repeats other tables' values: `pg_stats` samples
    // them in `histogram_bounds`, and `pg_stat_activity` and `pg_locks` show what sessions sent and hold. Whatever
    // initdb made has an oid below FirstNormalObjectId. KingbaseES builds these sources, so its `sys_catalog` and `sys`
    // are named too, in case its bootstrap counts past that oid.
    private static let firstNormalObjectId: UInt32 = 16_384
    private static let systemSchemas = Set(PostgreSQLPlugin.systemSchemaNames + ["sys_catalog", "sys"])

    static func isUserRelation(_ relation: UInt32, schema: String) -> Bool {
        relation >= firstNormalObjectId && !systemSchemas.contains(schema) && !schema.hasPrefix("pg_toast")
    }

    static func origins(for sources: [Source?], rows: [[PluginCellValue]]) -> [PluginColumnOrigin?] {
        var named: [Source: PluginColumnOrigin] = [:]
        for row in rows where row.count == 5 {
            guard let relation = row[0].asText.flatMap({ UInt32($0) }),
                  let attribute = row[1].asText.flatMap({ Int32($0) }),
                  let schema = row[2].asText,
                  let table = row[3].asText,
                  let column = row[4].asText,
                  isUserRelation(relation, schema: schema)
            else { continue }
            named[Source(relation: relation, attribute: attribute)] = PluginColumnOrigin(
                schema: schema, table: table, column: column
            )
        }
        return sources.map { $0.flatMap { named[$0] } }
    }
}
