//
//  TeradataObjectQueries.swift
//  TableProTeradataCore
//
//  Catalog SQL for routines and triggers. Pure, so it is testable without a server.
//

import Foundation

public enum TeradataObjectQueries {
    /// DBC.TablesV.TableKind is a single character. These are the ones that are routines or
    /// triggers rather than tables, views or indexes.
    public enum TableKind {
        public static let storedProcedure = "P"
        public static let externalProcedure = "E"
        public static let standardFunction = "F"
        public static let aggregateFunction = "A"
        public static let combinedFunction = "B"
        public static let tableFunction = "R"
        public static let orderedAnalyticFunction = "S"
        public static let macro = "M"
        public static let trigger = "G"

        public static let procedures = [storedProcedure, externalProcedure]
        public static let functions = [
            standardFunction, aggregateFunction, combinedFunction,
            tableFunction, orderedAnalyticFunction, macro,
        ]
    }

    public static func routineList(database: String) -> String {
        let kinds = (TableKind.procedures + TableKind.functions)
            .map { TeradataSchemaQueries.quoteLiteral($0) }
            .joined(separator: ", ")
        return """
            SELECT TableName, TableKind, DatabaseName, RequestText, CreatorName
            FROM DBC.TablesV
            WHERE DatabaseName = \(TeradataSchemaQueries.quoteLiteral(database))
            AND TableKind IN (\(kinds))
            ORDER BY TableKind, TableName
            """
    }

    public static func triggerList(database: String, table: String?) -> String {
        var query = """
            SELECT TriggerName, SubjectTableDataBaseName, TableName, ActionTime, Event, Kind, \
            EnabledFlag, RequestText, OrderNumber
            FROM DBC.TriggersV
            WHERE DatabaseName = \(TeradataSchemaQueries.quoteLiteral(database))
            """
        if let table {
            query += "\nAND TableName = \(TeradataSchemaQueries.quoteLiteral(table))"
        }
        return query + "\nORDER BY TableName, TriggerName"
    }

    /// SHOW PROCEDURE only returns text when the procedure was created with SPL retention on, so
    /// DBC.TablesV.RequestText is tried first and this is the fallback.
    public static func routineDefinition(kind: String, database: String, name: String) -> String {
        let qualified = TeradataSchemaQueries.qualifiedName(database: database, table: name)
        return TableKind.procedures.contains(kind)
            ? "SHOW PROCEDURE \(qualified)"
            : "SHOW FUNCTION \(qualified)"
    }

    public static func isProcedure(kind: String?) -> Bool {
        guard let kind = kind?.trimmingCharacters(in: .whitespaces) else { return false }
        return TableKind.procedures.contains(kind)
    }

    public static func timing(fromActionTime actionTime: String?) -> String {
        switch actionTime?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "B": return "BEFORE"
        case "A": return "AFTER"
        case "I": return "INSTEAD OF"
        default:  return actionTime?.trimmingCharacters(in: .whitespaces) ?? ""
        }
    }

    public static func event(fromEventCode event: String?) -> String {
        switch event?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "I": return "INSERT"
        case "U": return "UPDATE"
        case "D": return "DELETE"
        default:  return event?.trimmingCharacters(in: .whitespaces) ?? ""
        }
    }

    public static func orientation(fromKind kind: String?) -> String {
        kind?.trimmingCharacters(in: .whitespaces).uppercased() == "R" ? "ROW" : "STATEMENT"
    }
}
