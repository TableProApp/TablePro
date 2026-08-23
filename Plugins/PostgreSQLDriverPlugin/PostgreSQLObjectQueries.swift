//
//  PostgreSQLObjectQueries.swift
//  PostgreSQLDriverPlugin
//
//  Catalog SQL for routines and triggers. Pure, so it is testable without a server.
//

import Foundation

public enum PostgreSQLObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// `prokind` arrived in PostgreSQL 11, which is also the first release with procedures.
    public static let prokindMinimumServerVersion: Int32 = 110_000

    /// libpq answers 0 for a handle it has not connected, so an unknown version has to read as
    /// modern. Reading it as ancient emits `proisagg`, a column PostgreSQL 11 removed, and the
    /// whole routine list fails on every current server.
    public static func usesProkind(serverVersionNumber: Int32) -> Bool {
        serverVersionNumber <= 0 || serverVersionNumber >= prokindMinimumServerVersion
    }

    /// Reads pg_proc rather than information_schema.routines. information_schema shows only what
    /// the current user has a privilege on, and its routine_name repeats across overloads with no
    /// column that separates them; pg_proc has one row per routine and an oid that does.
    ///
    /// Aggregates (prokind 'a') and window functions ('w') are excluded because
    /// pg_get_functiondef raises on them, which would fail the whole listing over one object the
    /// viewer could not have shown anyway.
    public static func routineList(schema: String, serverVersionNumber: Int32) -> String {
        let schemaLiteral = escapeLiteral(schema)
        let modern = usesProkind(serverVersionNumber: serverVersionNumber)
        let kindColumn = modern
            ? "p.prokind"
            : "CASE WHEN p.proisagg THEN 'a' WHEN p.proiswindow THEN 'w' ELSE 'f' END"
        let kindFilter = modern
            ? "p.prokind IN ('f', 'p')"
            : "NOT p.proisagg AND NOT p.proiswindow"
        return """
            SELECT
                p.oid::text AS identity,
                p.proname AS name,
                n.nspname AS schema,
                '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')' AS arguments,
                pg_catalog.pg_get_function_result(p.oid) AS result,
                l.lanname AS language,
                \(kindColumn) AS kind,
                CASE p.provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END AS volatility,
                CASE WHEN p.prosecdef THEN 'DEFINER' ELSE 'INVOKER' END AS security,
                pg_catalog.pg_get_userbyid(p.proowner) AS owner
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            WHERE n.nspname = '\(schemaLiteral)'
                AND \(kindFilter)
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_depend d
                    WHERE d.objid = p.oid AND d.deptype = 'e'
                )
            ORDER BY p.proname, arguments
            """
    }

    /// Addressed by oid, so an overloaded name resolves to the exact routine the reader clicked
    /// instead of whichever row the planner happened to return first.
    public static func routineDefinition(identity: String) -> String {
        """
        SELECT pg_catalog.pg_get_functiondef('\(escapeLiteral(identity))'::oid)
        """
    }

    public static func routineDefinitionByName(name: String, schema: String, arguments: String?) -> String {
        let nameLiteral = escapeLiteral(name)
        let schemaLiteral = escapeLiteral(schema)
        let argumentsPredicate = arguments.map {
            "AND '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')' = '\(escapeLiteral($0))'"
        } ?? ""
        return """
            SELECT pg_catalog.pg_get_functiondef(p.oid)
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = '\(schemaLiteral)'
                AND p.proname = '\(nameLiteral)'
                \(argumentsPredicate)
            ORDER BY p.oid
            LIMIT 1
            """
    }

    /// One query for the whole schema. The per-table fetch is the same SELECT with one more
    /// predicate, so the two lists cannot disagree about a table they both cover.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = escapeLiteral(schema)
        let tablePredicate = table.map { "AND c.relname = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT
                t.tgname AS name,
                c.relname AS table_name,
                n.nspname AS schema,
                CASE WHEN (t.tgtype & 64) != 0 THEN 'INSTEAD OF'
                     WHEN (t.tgtype & 2)  != 0 THEN 'BEFORE'
                     ELSE 'AFTER' END AS timing,
                array_to_string(array_remove(ARRAY[
                    CASE WHEN (t.tgtype & 4)  != 0 THEN 'INSERT' END,
                    CASE WHEN (t.tgtype & 8)  != 0 THEN 'DELETE' END,
                    CASE WHEN (t.tgtype & 16) != 0 THEN 'UPDATE' END,
                    CASE WHEN (t.tgtype & 32) != 0 THEN 'TRUNCATE' END
                ], NULL), ' OR ') AS event,
                CASE WHEN (t.tgtype & 1) != 0 THEN 'ROW' ELSE 'STATEMENT' END AS orientation,
                t.tgenabled <> 'D' AS enabled,
                pg_catalog.pg_get_triggerdef(t.oid) AS definition,
                pg_catalog.pg_get_userbyid(c.relowner) AS owner
            FROM pg_catalog.pg_trigger t
            JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(schemaLiteral)'
                AND NOT t.tgisinternal
                \(tablePredicate)
            ORDER BY c.relname, t.tgname
            """
    }
}
