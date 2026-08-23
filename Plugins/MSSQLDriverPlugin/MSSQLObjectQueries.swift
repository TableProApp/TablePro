//
//  MSSQLObjectQueries.swift
//  MSSQLDriverPlugin
//
//  Catalog SQL for routines and triggers. Pure, so it is testable without a server.
//

import Foundation

public enum MSSQLObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// Reads sys.sql_modules, never INFORMATION_SCHEMA.ROUTINES.ROUTINE_DEFINITION. That column is
    /// nvarchar(4000) and silently returns the first 4000 characters of a longer body, which looks
    /// like a routine that ends mid-statement.
    public static func routineList(schema: String) -> String {
        let schemaLiteral = escapeLiteral(schema)
        return """
            SELECT
                o.name,
                s.name AS schema_name,
                o.type,
                m.definition,
                CASE WHEN m.definition IS NULL THEN 1 ELSE 0 END AS is_encrypted,
                (
                    SELECT STUFF((
                        SELECT ', ' + p.name + ' ' + TYPE_NAME(p.user_type_id)
                        FROM sys.parameters p
                        WHERE p.object_id = o.object_id AND p.parameter_id > 0
                        ORDER BY p.parameter_id
                        FOR XML PATH(''), TYPE
                    ).value('.', 'nvarchar(max)'), 1, 2, '')
                ) AS parameter_list,
                (
                    SELECT TOP 1 TYPE_NAME(r.user_type_id)
                    FROM sys.parameters r
                    WHERE r.object_id = o.object_id AND r.is_output = 1 AND r.parameter_id = 0
                ) AS return_type
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
            WHERE s.name = '\(schemaLiteral)'
                AND o.type IN ('P', 'FN', 'IF', 'TF')
                AND o.is_ms_shipped = 0
            ORDER BY o.type, o.name
            """
    }

    public static func routineDefinition(schema: String, name: String) -> String {
        """
        SELECT m.definition
        FROM sys.sql_modules m
        JOIN sys.objects o ON o.object_id = m.object_id
        JOIN sys.schemas s ON s.schema_id = o.schema_id
        WHERE s.name = '\(escapeLiteral(schema))' AND o.name = '\(escapeLiteral(name))'
        """
    }

    /// One row per trigger per event, so the caller folds the events back together. Filtering to
    /// one table is one more predicate on the same query, so the per-table list and the
    /// schema-wide list cannot disagree.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = escapeLiteral(schema)
        let tablePredicate = table.map { "AND parent.name = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT
                t.name,
                parent.name AS table_name,
                s.name AS schema_name,
                t.is_instead_of_trigger,
                te.type_desc AS event,
                t.is_disabled,
                OBJECT_DEFINITION(t.object_id) AS definition
            FROM sys.triggers t
            JOIN sys.objects parent ON parent.object_id = t.parent_id
            JOIN sys.schemas s ON s.schema_id = parent.schema_id
            JOIN sys.trigger_events te ON te.object_id = t.object_id
            WHERE t.parent_class = 1
                AND s.name = '\(schemaLiteral)'
                \(tablePredicate)
            ORDER BY parent.name, t.name, te.type_desc
            """
    }

    public static func routineKind(forObjectType type: String) -> String {
        type.trimmingCharacters(in: .whitespaces).uppercased() == "P" ? "PROCEDURE" : "FUNCTION"
    }
}
