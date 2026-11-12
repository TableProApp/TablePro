//
//  CassandraConditionalWrite.swift
//  TableProCassandraCore
//

import Foundation
import TableProSQLGrammar

// A grid write names its row by key and is conditioned on it: an INSERT is an upsert, and an UPDATE writes its cells
// whether or not the row is there, so either would otherwise replace or recreate a row the grid never showed.
// A condition that fails answers one row whose `[applied]` is false, which the server reports as a success.
public enum CassandraConditionalWrite {
    public static let appliedColumn = "[applied]"
    public static let insertCondition = "IF NOT EXISTS"
    public static let updateCondition = "IF EXISTS"

    private static let grammar = SQLLexicalReadings.resolve(databaseTypeId: "Cassandra", declared: nil, session: nil)
        .execution

    public enum Refusal: Sendable, Equatable {
        case keyTaken
        case rowMissing
    }

    public static func insertStatement(target: String, names: [String], values: [String]) -> String {
        "INSERT INTO \(target) (\(names.joined(separator: ", "))) VALUES (\(values.joined(separator: ", "))) "
            + insertCondition
    }

    public static func updateStatement(
        target: String,
        assignments: [String],
        keyCondition: String,
        timeToLive: Int? = nil
    ) -> String {
        "UPDATE \(target)\(usingClause(timeToLive: timeToLive)) SET \(assignments.joined(separator: ", ")) "
            + "WHERE \(keyCondition) \(updateCondition)"
    }

    public static func usingClause(timeToLive: Int?) -> String {
        timeToLive.map { " USING TTL \($0)" } ?? ""
    }

    public static func batch(_ statements: [String]) -> String {
        "BEGIN BATCH " + statements.map { $0 + "; " }.joined() + "APPLY BATCH"
    }

    public static func refusal(statement: String, firstColumn: String?, firstValue: String?) -> Refusal? {
        guard firstColumn == appliedColumn, firstValue?.lowercased() == "false" else { return nil }
        if let statements = CQLBatch.statements(in: statement, grammar: grammar) {
            return batchRefusal(statements)
        }
        let normalized = statement.uppercased()
        if normalized.hasPrefix("INSERT"), normalized.hasSuffix(" " + insertCondition) {
            return .keyTaken
        }
        if normalized.hasPrefix("UPDATE"), normalized.hasSuffix(" " + updateCondition) {
            return .rowMissing
        }
        return nil
    }

    // An edit whose cells keep different TTLs is a batch of UPDATEs on the row, each IF EXISTS or, for static
    // cells, unconditioned. A batch with any other statement or condition is left to its result.
    private static func batchRefusal(_ statements: [String]) -> Refusal? {
        var holdsRow = false
        for statement in statements {
            let words = codeWords(statement)
            guard words.first == "UPDATE" else { return nil }
            guard let condition = words.firstIndex(of: "IF") else { continue }
            guard words[condition...].elementsEqual(["IF", "EXISTS"]) else { return nil }
            holdsRow = true
        }
        return holdsRow ? .rowMissing : nil
    }

    private static func codeWords(_ statement: String) -> [String] {
        SQLCodeProjection.code(of: statement, grammar: grammar)
            .uppercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map(String.init)
    }
}
