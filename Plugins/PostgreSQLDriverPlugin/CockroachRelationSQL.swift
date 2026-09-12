//
//  CockroachRelationSQL.swift
//  PostgreSQLDriverPlugin
//
//  CockroachDB's SHOW statements for one relation. Pure, so it is testable without a server.
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
}
