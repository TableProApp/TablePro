//
//  TriggerSQLParser.swift
//  TableProPluginKit
//
//  Extracts trigger timing and event from a CREATE TRIGGER statement.
//

import Foundation

public enum TriggerSQLParser {
    private static let events: Set<String> = ["INSERT", "UPDATE", "DELETE"]

    public static func timingAndEvent(from sql: String) -> (timing: String, event: String) {
        let upper = sql.uppercased()
        let headerEnd = upper.range(of: " ON ")?.lowerBound ?? upper.endIndex
        let tokens = upper[upper.startIndex..<headerEnd]
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)

        for index in tokens.indices {
            let token = tokens[index]
            if token == "INSTEAD", index + 2 < tokens.count, tokens[index + 1] == "OF",
               events.contains(tokens[index + 2]) {
                return ("INSTEAD OF", tokens[index + 2])
            }
            if token == "BEFORE" || token == "AFTER", index + 1 < tokens.count,
               events.contains(tokens[index + 1]) {
                return (token, tokens[index + 1])
            }
        }
        return ("", "")
    }
}
