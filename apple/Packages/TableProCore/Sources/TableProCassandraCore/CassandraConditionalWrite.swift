//
//  CassandraConditionalWrite.swift
//  TableProCassandraCore
//

import Foundation

// A grid write names its row by key and is conditioned on it: an INSERT is an upsert, and an UPDATE writes its cells
// whether or not the row is there, so either would otherwise replace or recreate a row the grid never showed.
// A condition that fails answers one row whose `[applied]` is false, which the server reports as a success.
public enum CassandraConditionalWrite {
    public static let appliedColumn = "[applied]"
    public static let insertCondition = "IF NOT EXISTS"
    public static let updateCondition = "IF EXISTS"

    public enum Refusal: Sendable, Equatable {
        case keyTaken
        case rowMissing
    }

    public static func insertStatement(target: String, names: [String], values: [String]) -> String {
        "INSERT INTO \(target) (\(names.joined(separator: ", "))) VALUES (\(values.joined(separator: ", "))) "
            + insertCondition
    }

    public static func updateStatement(target: String, assignments: [String], keyCondition: String) -> String {
        "UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(keyCondition) \(updateCondition)"
    }

    public static func refusal(statement: String, firstColumn: String?, firstValue: String?) -> Refusal? {
        guard firstColumn == appliedColumn, firstValue?.lowercased() == "false" else { return nil }
        let normalized = statement.uppercased()
        if normalized.hasPrefix("INSERT"), normalized.hasSuffix(" " + insertCondition) {
            return .keyTaken
        }
        if normalized.hasPrefix("UPDATE"), normalized.hasSuffix(" " + updateCondition) {
            return .rowMissing
        }
        return nil
    }
}
