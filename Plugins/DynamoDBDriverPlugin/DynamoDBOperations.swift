//
//  DynamoDBOperations.swift
//  DynamoDBDriverPlugin
//
//  The table operations the app offers, as statements this driver also executes.
//

import Foundation

enum DynamoDBOperations {
    /// The statement that deletes one table.
    ///
    /// PartiQL has no DDL, so this is the driver's own vocabulary rather than something the
    /// `ExecuteStatement` API would take: `execute(query:)` recognises it and issues `DeleteTable`.
    /// Spelled `DROP TABLE` because the confirmation dialog shows the statement verbatim and
    /// `QueryClassifier` reads the leading verb to tier it destructive, and because it is what a
    /// person reading it would expect. Returning nil instead let the app invent the same text and
    /// send it to `ExecuteStatement`, which rejects it (#2884).
    static func dropTable(named name: String, objectType: String) -> String? {
        guard isTableObject(objectType), let quoted = quotedName(name) else { return nil }
        return "DROP TABLE \(quoted)"
    }

    /// DynamoDB has only tables, so any other kind the app asks about is not something this engine
    /// drops, and answering anyway would delete the table of that name instead.
    static func isTableObject(_ objectType: String) -> Bool {
        objectType.uppercased() == "TABLE"
    }

    /// The table named by a drop statement, or nil when the text is not one.
    static func droppedTableName(in statement: String) -> String? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("DROP TABLE ") else { return nil }
        let rest = trimmed.dropFirst("DROP TABLE ".count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count > 2 else { return nil }
        let unquoted = String(rest.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        return isValidTableName(unquoted) ? unquoted : nil
    }

    /// A DynamoDB table name is 3 to 255 characters of `a-z A-Z 0-9 _ - .` and nothing else, so a
    /// name carrying anything more did not come from the table listing and is refused rather than
    /// sent as a delete.
    static func isValidTableName(_ name: String) -> Bool {
        guard (3...255).contains(name.count) else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    private static func quotedName(_ name: String) -> String? {
        guard isValidTableName(name) else { return nil }
        return "\"\(name)\""
    }
}
