//
//  CockroachRelationSQL.swift
//  PostgreSQLDriverPlugin
//
//  CockroachDB catalog statements. Pure, so they are testable without a server.
//

import Foundation
import TableProPluginKit

/// Every statement names the schema of the object asked for, never the session's own schema.
/// CockroachDB resolves a two-part `schema.object` name against the connection's current database,
/// so two parts are all these reads need and the session schema is never consulted. Reading
/// `currentSchema` instead sent an export or a compare of an object outside the connection's schema
/// at a same-named object in that schema, or at no object at all.
///
/// `schema` is non-optional on purpose: the `?? currentSchema` fallback stays at the call site,
/// where the driver knows its own session, so no caller can reach these builders without one.
public enum CockroachRelationSQL {
    public static func showCreateTable(table: String, schema: String) -> String {
        "SHOW CREATE TABLE \(PostgreSQLObjectQueries.qualifiedName(schema: schema, name: table))"
    }

    public static func showCreateView(view: String, schema: String) -> String {
        "SHOW CREATE VIEW \(PostgreSQLObjectQueries.qualifiedName(schema: schema, name: view))"
    }

    public static func showIndexes(table: String, schema: String) -> String {
        "SHOW INDEXES FROM \(PostgreSQLObjectQueries.qualifiedName(schema: schema, name: table))"
    }

    /// The key subquery pairs a constraint with its own table: CockroachDB names constraints per
    /// table, so pairing on name and schema alone joined every table's `primary` to every other's.
    static func columnsQuery(schema: String, table: String?) -> String {
        ColumnQueryShape.informationSchemaColumnsQuery(schema: schema, table: table)
    }
}
