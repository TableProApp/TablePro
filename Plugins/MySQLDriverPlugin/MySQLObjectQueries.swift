//
//  MySQLObjectQueries.swift
//  MySQLDriverPlugin
//
//  Catalog SQL for routines and triggers, and the rule every catalog read shares for naming the
//  database it means. Pure, so it is testable without a server.
//

import Foundation

public enum MySQLObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        mysqlEscapeStringLiteral(value)
    }

    public static func quoteIdentifier(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }

    /// The database a catalog read means.
    ///
    /// These engines have no schema layer, so every `schema:` the driver protocol hands them is a
    /// database name, and a caller that names none means the one the connection is already on. That
    /// fallback is the whole rule: an unqualified name resolves against the session's current
    /// database, so a read that drops the caller's schema silently answers about a same-named table
    /// somewhere else.
    public static func effectiveSchema(_ schema: String?, activeDatabase: String) -> String {
        guard let schema, !schema.isEmpty else { return activeDatabase }
        return schema
    }

    /// Quoting is the caller's, not this file's: Databend answers the same protocol through the same
    /// driver and escapes a backtick-bearing name by switching to double quotes, so rendering one
    /// here with the MySQL quoter would corrupt it.
    public static func qualifiedIdentifier(
        schema: String?,
        name: String,
        quote: (String) -> String
    ) -> String {
        guard let schema, !schema.isEmpty else { return quote(name) }
        return "\(quote(schema)).\(quote(name))"
    }

    public static func qualifiedIdentifier(schema: String?, name: String) -> String {
        qualifiedIdentifier(schema: schema, name: name, quote: quoteIdentifier)
    }

    /// Lists a schema's tables, with the partition count joined in for the ones that have any.
    ///
    /// `information_schema.PARTITIONS` holds one all-null row for a table that is not partitioned,
    /// so `PARTITION_NAME IS NOT NULL` is what separates the two. A subpartitioned table repeats its
    /// partition name once per subpartition, so the count is over distinct names rather than rows.
    ///
    /// The grouping and the join are both binary. `INFORMATION_SCHEMA` compares identifiers
    /// case-insensitively, so on a server with `lower_case_table_names=0` a schema holding both
    /// `orders` and `Orders` would merge their counts and could label the unpartitioned one
    /// `PARTITIONED TABLE`.
    ///
    /// `includePartitions` is false for Databend, which answers the same wire protocol through the
    /// same driver without this catalog.
    public static func tableList(schema: String, includePartitions: Bool) -> String {
        let schemaLiteral = escapeLiteral(schema)
        guard includePartitions else {
            return """
                SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COMMENT, NULL
                FROM information_schema.TABLES t
                WHERE t.TABLE_SCHEMA = '\(schemaLiteral)'
                """
        }
        return """
            SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COMMENT, p.PARTITION_COUNT
            FROM information_schema.TABLES t
            LEFT JOIN (
                SELECT TABLE_NAME AS P_TABLE_NAME, COUNT(DISTINCT PARTITION_NAME) AS PARTITION_COUNT
                FROM information_schema.PARTITIONS
                WHERE TABLE_SCHEMA = '\(schemaLiteral)' AND PARTITION_NAME IS NOT NULL
                GROUP BY BINARY TABLE_NAME, TABLE_NAME
            ) p ON BINARY p.P_TABLE_NAME = BINARY t.TABLE_NAME
            WHERE t.TABLE_SCHEMA = '\(schemaLiteral)'
            """
    }

    /// One table's partitions, subpartitions included. A subpartition arrives as its own row
    /// carrying its parent partition's name, ordered so the parent is read before its children.
    public static func partitionList(schema: String, table: String) -> String {
        """
        SELECT PARTITION_NAME, SUBPARTITION_NAME, PARTITION_METHOD, PARTITION_DESCRIPTION,
               PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION, TABLE_ROWS
        FROM information_schema.PARTITIONS
        WHERE TABLE_SCHEMA = '\(escapeLiteral(schema))'
          AND TABLE_NAME = '\(escapeLiteral(table))'
          AND PARTITION_NAME IS NOT NULL
        ORDER BY PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION
        """
    }

    /// The parameter list comes from information_schema.PARAMETERS, where ordinal 0 is a function's
    /// return value rather than a parameter.
    public static func routineList(schema: String) -> String {
        let schemaLiteral = escapeLiteral(schema)
        return """
            SELECT
                r.ROUTINE_NAME,
                r.ROUTINE_TYPE,
                r.DTD_IDENTIFIER,
                r.SQL_DATA_ACCESS,
                r.IS_DETERMINISTIC,
                r.SECURITY_TYPE,
                r.DEFINER,
                r.ROUTINE_SCHEMA,
                (
                    SELECT GROUP_CONCAT(
                        CONCAT_WS(' ', p.PARAMETER_MODE, p.PARAMETER_NAME, p.DTD_IDENTIFIER)
                        ORDER BY p.ORDINAL_POSITION SEPARATOR ', '
                    )
                    FROM information_schema.PARAMETERS p
                    WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA
                        AND p.SPECIFIC_NAME = r.ROUTINE_NAME
                        AND p.ROUTINE_TYPE = r.ROUTINE_TYPE
                        AND p.ORDINAL_POSITION > 0
                ) AS PARAMETER_LIST
            FROM information_schema.ROUTINES r
            WHERE r.ROUTINE_SCHEMA = '\(schemaLiteral)'
            ORDER BY r.ROUTINE_TYPE, r.ROUTINE_NAME
            """
    }

    /// Qualified with the schema. Unqualified, the server resolves the name against the session
    /// database instead of the one being browsed, and returns a different routine's body or none.
    public static func routineDefinition(kind: String, schema: String?, name: String) -> String {
        "SHOW CREATE \(kind) \(qualifiedIdentifier(schema: schema, name: name))"
    }

    /// One builder for both scopes: the per-table fetch adds a predicate and nothing else, so the
    /// Structure tab and the sidebar cannot disagree about a table's triggers.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = escapeLiteral(schema)
        let tablePredicate = table.map { "AND EVENT_OBJECT_TABLE = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT
                TRIGGER_NAME,
                EVENT_OBJECT_TABLE,
                EVENT_OBJECT_SCHEMA,
                ACTION_TIMING,
                EVENT_MANIPULATION,
                ACTION_ORIENTATION,
                ACTION_STATEMENT,
                ACTION_CONDITION,
                DEFINER,
                ACTION_ORDER
            FROM information_schema.TRIGGERS
            WHERE EVENT_OBJECT_SCHEMA = '\(schemaLiteral)'
                \(tablePredicate)
            ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME
            """
    }

    /// information_schema holds the parts of a trigger but not its text, so the statement is
    /// assembled. Dropping DEFINER or the WHEN clause would produce something that looks runnable
    /// and is not the trigger the server holds.
    public static func triggerStatement(
        name: String,
        table: String,
        schema: String?,
        timing: String,
        event: String,
        orientation: String?,
        condition: String?,
        definer: String?
    ) -> String {
        var header = "CREATE"
        if let definer, !definer.isEmpty {
            header += " DEFINER = \(quotedDefiner(definer))"
        }
        header += " TRIGGER \(qualifiedIdentifier(schema: schema, name: name))"
        header += " \(timing) \(event) ON \(qualifiedIdentifier(schema: schema, name: table))"
        header += " FOR EACH \(orientation?.isEmpty == false ? orientation ?? "ROW" : "ROW")"
        if let condition, !condition.isEmpty {
            header += " WHEN (\(condition))"
        }
        return header
    }

    /// A DEFINER arrives as `user@host` and both halves are identifiers, so quoting the whole
    /// string produces a name no server will accept.
    public static func quotedDefiner(_ definer: String) -> String {
        guard let separator = definer.lastIndex(of: "@") else { return quoteIdentifier(definer) }
        let user = String(definer[definer.startIndex ..< separator])
        let host = String(definer[definer.index(after: separator)...])
        return "\(quoteIdentifier(user))@\(quoteIdentifier(host))"
    }
}
