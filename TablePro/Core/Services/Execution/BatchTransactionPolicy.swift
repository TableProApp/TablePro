//
//  BatchTransactionPolicy.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum BatchTransactionPolicy {
    private static let sessionScopes: Set<String> = ["SESSION", "LOCAL", "@@SESSION", "@@LOCAL"]
    private static let commitModeVariables: Set<String> = ["AUTOCOMMIT", "IMPLICIT_TRANSACTIONS"]
    private static let wordsNeeded = 3

    static func wrapsInTransaction(_ statements: [String], dialect: SqlDialect) -> Bool {
        !statements.contains { takesTransactionControl($0, dialect: dialect) }
    }

    private static func takesTransactionControl(_ statement: String, dialect: SqlDialect) -> Bool {
        let words = leadingWords(of: statement)
        guard let first = words.first else { return false }
        let following = words.dropFirst().first
        switch first {
        case "BEGIN":
            return SqlBlockStructure.beginStartsTransaction(followedBy: following)
        case "START":
            return following == "TRANSACTION"
        case "XA":
            return following == "START" || following == "BEGIN"
        case "SET":
            return setsTransactionControl(Array(words.dropFirst()), dialect: dialect)
        default:
            return false
        }
    }

    private static func setsTransactionControl(_ words: [String], dialect: SqlDialect) -> Bool {
        guard let target = words.first else { return false }
        if target == "TRANSACTION" { return dialect == .mysql }
        guard let variable = sessionScopes.contains(target) ? words.dropFirst().first : target else { return false }
        let name = variable.hasPrefix("@@") ? String(variable.dropFirst(2)) : variable
        return commitModeVariables.contains(name)
    }

    private static func leadingWords(of statement: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in executableText(of: statement).unicodeScalars {
            if scalar == ";" { break }
            if isWordScalar(scalar) {
                current.append(scalar)
                continue
            }
            guard !current.isEmpty else { continue }
            words.append(String(current).uppercased())
            current.removeAll()
            if words.count == wordsNeeded { return words }
        }
        if !current.isEmpty {
            words.append(String(current).uppercased())
        }
        return words
    }

    private static func executableText(of statement: String) -> Substring {
        let text = QueryClassifier.strippingLeadingComments(statement)[...]
        return QueryClassifier.conditionalCommentBody(of: text) ?? text
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "@" || CharacterSet.alphanumerics.contains(scalar)
    }
}
