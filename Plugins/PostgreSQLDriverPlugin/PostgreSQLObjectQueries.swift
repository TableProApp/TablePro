//
//  PostgreSQLObjectQueries.swift
//  PostgreSQLDriverPlugin
//
//  Catalog SQL for routines, triggers and user-defined types. Pure, so it is testable without a
//  server.
//

import Foundation
import TableProPluginKit

public enum PostgreSQLObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// A literal that reads the same whatever `standard_conforming_strings` is set to. Doubling the
    /// quote is enough while the value has no backslash; with one, a server running the legacy
    /// setting would let `\'` swallow a doubled quote and close the literal early, so such a value
    /// is written as an `E''` string, where a backslash is always an escape and is doubled here.
    public static func quoteLiteral(_ value: String) -> String {
        guard value.contains("\\") else { return "'\(escapeLiteral(value))'" }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "E'\(escaped)'"
    }

    public static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public static func qualifiedName(schema: String, name: String) -> String {
        "\(quoteIdentifier(schema)).\(quoteIdentifier(name))"
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

    /// The named types a user created, with everything the CREATE statement needs.
    ///
    /// Every table owns a composite type of its own row, so composites are kept only where the
    /// backing relation is a stand-alone type (`relkind = 'c'`). Types an extension installed are
    /// excluded the way extension routines are. Arrays and the multirange PostgreSQL 14 creates
    /// beside every range are other `typtype`s and never match. PostgreSQL 17 records a domain's
    /// NOT NULL as a constraint row too, so the constraint list keeps CHECK constraints alone and
    /// NOT NULL comes from `typnotnull`. The projection order is `PostgreSQLTypeDefinition.Column`.
    ///
    /// A listing names a schema; a reload names an oid and no schema, because a type keeps its oid
    /// when it is moved. Naming neither would list the whole database, so a caller passes one.
    public static func userDefinedTypeList(schema: String?, identity: String?, serverVersionNumber: Int32) -> String {
        let capabilities = PostgreSQLCapabilities.assumingModernWhenUnknown(serverVersionNumber)
        let schemaPredicate = schema.map { "AND n.nspname = \(quoteLiteral($0))" } ?? ""
        let identityPredicate = identity.flatMap { UInt32($0) }.map { "AND t.oid = \($0)::oid" } ?? ""
        let kinds = capabilities.hasRangeTypes ? "('e', 'c', 'd', 'r')" : "('e', 'c', 'd')"
        let fields = capabilities.hasJsonBuildObject ? """
            (SELECT json_agg(json_build_object(
                    'name', a.attname,
                    'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
                    'collation', CASE WHEN a.attcollation <> 0 AND a.attcollation <> ty.typcollation
                        THEN \(collationName("a.attcollation")) END) ORDER BY a.attnum)
                FROM pg_catalog.pg_attribute a
                JOIN pg_catalog.pg_type ty ON ty.oid = a.atttypid
                WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped)::text
            """ : "NULL::text"
        let constraints = capabilities.hasJsonBuildObject ? """
            (SELECT json_agg(json_build_object('name', con.conname, 'definition', pg_catalog.pg_get_constraintdef(con.oid)) ORDER BY con.conname)
                FROM pg_catalog.pg_constraint con
                WHERE con.contypid = t.oid AND con.contype = 'c')::text
            """ : "NULL::text"
        let rangeJoin = capabilities.hasRangeTypes ? "LEFT JOIN pg_catalog.pg_range r ON r.rngtypid = t.oid" : ""
        let rangeSubtype = capabilities.hasRangeTypes
            ? "CASE WHEN t.typtype = 'r' THEN pg_catalog.format_type(r.rngsubtype, NULL) END"
            : "NULL::text"
        let rangeCanonical = capabilities.hasRangeTypes
            ? "CASE WHEN t.typtype = 'r' AND r.rngcanonical <> 0 THEN r.rngcanonical::regproc::text END"
            : "NULL::text"
        let rangeSubtypeDiff = capabilities.hasRangeTypes
            ? "CASE WHEN t.typtype = 'r' AND r.rngsubdiff <> 0 THEN r.rngsubdiff::regproc::text END"
            : "NULL::text"
        let rangeOpclass = capabilities.hasRangeTypes ? """
            CASE WHEN t.typtype = 'r' THEN
                (SELECT pg_catalog.quote_ident(opn.nspname) || '.' || pg_catalog.quote_ident(opc.opcname)
                    FROM pg_catalog.pg_opclass opc
                    JOIN pg_catalog.pg_namespace opn ON opn.oid = opc.opcnamespace
                    WHERE opc.oid = r.rngsubopc AND NOT opc.opcdefault)
            END
            """ : "NULL::text"
        let rangeCollation = capabilities.hasRangeTypes ? """
            CASE WHEN t.typtype = 'r' AND r.rngcollation <> 0
                 AND r.rngcollation <> (SELECT st.typcollation FROM pg_catalog.pg_type st WHERE st.oid = r.rngsubtype)
                 THEN \(collationName("r.rngcollation"))
            END
            """ : "NULL::text"
        let rangeMultirange = capabilities.hasMultirangeTypes ? """
            CASE WHEN t.typtype = 'r' THEN
                (SELECT pg_catalog.quote_ident(mn.nspname) || '.' || pg_catalog.quote_ident(m.typname)
                    FROM pg_catalog.pg_type m
                    JOIN pg_catalog.pg_namespace mn ON mn.oid = m.typnamespace
                    WHERE m.oid = r.rngmultitypid)
            END
            """ : "NULL::text"
        return """
            SELECT
                t.oid::text AS identity,
                t.typname AS name,
                n.nspname AS schema,
                t.typtype::text AS kind,
                pg_catalog.pg_get_userbyid(t.typowner) AS owner,
                pg_catalog.obj_description(t.oid, 'pg_type') AS comment,
                (SELECT json_agg(e.enumlabel ORDER BY e.enumsortorder)
                    FROM pg_catalog.pg_enum e WHERE e.enumtypid = t.oid)::text AS enum_labels,
                \(fields) AS fields,
                CASE WHEN t.typtype = 'd' THEN pg_catalog.format_type(t.typbasetype, t.typtypmod) END AS base_type,
                CASE WHEN t.typtype = 'd' AND t.typcollation <> 0
                     AND t.typcollation <> (SELECT b.typcollation FROM pg_catalog.pg_type b WHERE b.oid = t.typbasetype)
                     THEN \(collationName("t.typcollation"))
                END AS collation,
                t.typnotnull::text AS not_null,
                t.typdefault AS default_value,
                \(constraints) AS constraints,
                \(rangeSubtype) AS range_subtype,
                \(rangeCanonical) AS range_canonical,
                \(rangeSubtypeDiff) AS range_subtype_diff,
                \(rangeOpclass) AS range_opclass,
                \(rangeCollation) AS range_collation,
                \(rangeMultirange) AS range_multirange,
                pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(t.typname) AS spelling
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
            LEFT JOIN pg_catalog.pg_class c ON c.oid = t.typrelid
            \(rangeJoin)
            WHERE t.typtype IN \(kinds)
                AND (t.typtype <> 'c' OR c.relkind = 'c')
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_depend d
                    WHERE d.classid = 'pg_catalog.pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e'
                )
                \(schemaPredicate)
                \(identityPredicate)
            ORDER BY t.typname
            """
    }

    /// The qualified, quoted name of a collation oid, spelled the way a COLLATE clause takes it.
    private static func collationName(_ oidExpression: String) -> String {
        """
        (SELECT pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(co.collname)
            FROM pg_catalog.pg_collation co
            JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
            WHERE co.oid = \(oidExpression))
        """
    }

    public static func addEnumLabel(
        schema: String,
        name: String,
        label: String,
        placement: PluginEnumLabelPlacement?,
        ifNotExists: Bool
    ) -> String {
        let clause = ifNotExists ? "ADD VALUE IF NOT EXISTS" : "ADD VALUE"
        var statement = "ALTER TYPE \(qualifiedName(schema: schema, name: name)) \(clause) \(quoteLiteral(label))"
        if let placement {
            statement += " \(placement.placesBefore ? "BEFORE" : "AFTER") \(quoteLiteral(placement.anchor))"
        }
        return statement
    }

    public static func renameEnumLabel(schema: String, name: String, from oldLabel: String, to newLabel: String) -> String {
        "ALTER TYPE \(qualifiedName(schema: schema, name: name)) RENAME VALUE \(quoteLiteral(oldLabel)) TO \(quoteLiteral(newLabel))"
    }

    public static func createTypeTemplate(schema: String) -> String {
        """
        CREATE TYPE \(qualifiedName(schema: schema, name: "type_name")) AS ENUM (
            'value_1',
            'value_2'
        );
        """
    }
}
