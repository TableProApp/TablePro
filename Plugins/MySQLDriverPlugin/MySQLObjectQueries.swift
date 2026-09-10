//
//  MySQLObjectQueries.swift
//  MySQLDriverPlugin
//
//  Catalog SQL for routines and triggers. Pure, so it is testable without a server.
//

import Foundation

public enum MySQLObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    public static func quoteIdentifier(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }

    public static func qualifiedIdentifier(schema: String?, name: String) -> String {
        guard let schema, !schema.isEmpty else { return quoteIdentifier(name) }
        return "\(quoteIdentifier(schema)).\(quoteIdentifier(name))"
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
