//
//  OracleObjectQueries.swift
//  OracleDriverPlugin
//
//  Catalog SQL for routines and triggers. Pure, so it is testable without a server.
//

import Foundation

public enum OracleObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Standalone procedures and functions only. A packaged routine is addressed through its
    /// package, which is a different object with a different DDL call, so listing it here would
    /// produce rows whose source cannot be fetched.
    /// Standalone procedures and functions only. A packaged routine is addressed through its
    /// package, which is a different object with a different DDL call, so listing it here would
    /// produce rows whose source cannot be fetched.
    ///
    /// No argument list is built. Oracle only allows overloading inside a package, so a standalone
    /// routine is identified by its name alone, and the LISTAGG that would assemble a signature
    /// raises ORA-01489 past 4000 bytes, which fails the whole listing over one wide signature.
    public static func routineList(schema: String) -> String {
        let schemaLiteral = escapeLiteral(schema)
        return """
            SELECT
                o.OBJECT_NAME,
                o.OWNER,
                o.OBJECT_TYPE,
                o.STATUS
            FROM ALL_OBJECTS o
            WHERE o.OWNER = '\(schemaLiteral)'
              AND o.OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION')
            ORDER BY o.OBJECT_TYPE, o.OBJECT_NAME
            """
    }

    /// ALL_SOURCE stores one row per line, so the body has to be reassembled in LINE order.
    /// DBMS_METADATA.GET_DDL is nicer but returns nothing rather than raising when the caller
    /// lacks SELECT_CATALOG_ROLE for another schema, which reads as a routine that vanished.
    public static func routineSource(schema: String, name: String, type: String) -> String {
        """
        SELECT TEXT
        FROM ALL_SOURCE
        WHERE OWNER = '\(escapeLiteral(schema))'
          AND NAME = '\(escapeLiteral(name))'
          AND TYPE = '\(escapeLiteral(type))'
        ORDER BY LINE
        """
    }

    /// TRIGGER_BODY is the part the previous query never selected, which left the viewer showing a
    /// CREATE OR REPLACE header with no body under it.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = escapeLiteral(schema)
        /// A schema browse asks for the triggers this schema owns, which is OWNER. A per-table
        /// fetch asks for the triggers on that table, which is TABLE_OWNER plus TABLE_NAME. They
        /// differ for a trigger one schema owns on another schema's table.
        let scope = table.map {
            "TABLE_OWNER = '\(schemaLiteral)' AND TABLE_NAME = '\(escapeLiteral($0))'"
        } ?? "OWNER = '\(schemaLiteral)'"
        return """
            SELECT
                TRIGGER_NAME,
                TABLE_NAME,
                OWNER,
                TRIGGER_TYPE,
                TRIGGERING_EVENT,
                STATUS,
                WHEN_CLAUSE,
                DESCRIPTION,
                TRIGGER_BODY
            FROM ALL_TRIGGERS
            WHERE \(scope)
            ORDER BY TABLE_NAME, TRIGGER_NAME
            """
    }

    public static func timing(fromTriggerType triggerType: String) -> String {
        let upper = triggerType.uppercased()
        if upper.contains("INSTEAD OF") { return "INSTEAD OF" }
        if upper.hasPrefix("BEFORE") { return "BEFORE" }
        return "AFTER"
    }

    public static func orientation(fromTriggerType triggerType: String) -> String {
        triggerType.uppercased().contains("EACH ROW") ? "ROW" : "STATEMENT"
    }

    /// ALL_TRIGGERS.DESCRIPTION holds the trigger's name, its timing, its events, the table and
    /// the WHEN clause, exactly as they would follow CREATE OR REPLACE TRIGGER. Assembling that
    /// header ourselves from the separate columns is how the old code lost the WHEN clause.
    public static func triggerDefinition(description: String?, body: String?, name: String) -> String {
        let header = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "CREATE OR REPLACE TRIGGER "
        guard let header, !header.isEmpty else {
            guard let trimmedBody, !trimmedBody.isEmpty else { return "" }
            return "\(prefix)\(quoteIdentifier(name))\n\(trimmedBody)"
        }
        guard let trimmedBody, !trimmedBody.isEmpty else {
            return "\(prefix)\(header)"
        }
        return "\(prefix)\(header)\n\(trimmedBody)"
    }
}
