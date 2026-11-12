//
//  AutocommitOnlyStatement+Teradata.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar
import TableProUtilities

internal extension AutocommitOnlyStatement {
    // Inside a transaction Teradata takes nothing after DDL but its end: failure 3932 in Teradata mode, error 3722 in
    // ANSI. DDL is what the SQL Data Definition Language manual lists, less HELP and SHOW; the ANSI transaction rules
    // name DATABASE and SET SESSION, and the Data Control Language manual puts GRANT, REVOKE and GIVE under the same
    // rule. Unmeasured: there is no Teradata server here.
    static func matchesTeradata(_ statement: NSString, grammar: SQLLexicalGrammar) -> Bool {
        var cursor = SQLTokenCursor(statement, grammar: grammar)
        guard let keyword = cursor.next()?.word else { return false }
        if teradataDefinitionKeywords.contains(keyword) { return true }
        let following = cursor.next()?.word ?? ""
        switch keyword {
        case "BEGIN", "END":
            return teradataLoggingTargets.contains(following)
        case "CHECKPOINT":
            return following == "ISOLATED"
        case "COLLECT":
            return teradataStatisticsWords.contains(following)
        case "DELETE":
            return following == "DATABASE" || following == "USER"
        case "SET":
            guard following == "QUERY_BAND" else { return teradataSessionSettings.contains(following) }
            return queryBandScope(&cursor) != "TRANSACTION"
        default:
            return false
        }
    }

    // DATABASE, SET SESSION DATABASE and its SS abbreviation move the session's default database.
    static func movesDatabase(_ statement: String, family: TransactionEngineFamily, grammar: SQLLexicalGrammar) -> Bool {
        guard family == .teradata else { return false }
        var cursor = SQLTokenCursor(statement as NSString, grammar: grammar)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "DATABASE":
            return true
        case "SET":
            guard cursor.next()?.word == "SESSION" else { return false }
            return cursor.next()?.word == "DATABASE"
        case "SS":
            return cursor.next()?.word == "DATABASE"
        default:
            return false
        }
    }
}

private extension AutocommitOnlyStatement {
    // CT is the CREATE TABLE abbreviation the CREATE TABLE syntax diagram gives.
    static let teradataDefinitionKeywords: Set<String> = [
        "CREATE", "CT", "ALTER", "DROP", "RENAME", "REPLACE", "COMMENT", "MODIFY", "DATABASE", "FLUSH", "LOGGING",
        "INCREMENTAL", "GRANT", "REVOKE", "GIVE"
    ]

    static let teradataLoggingTargets: Set<String> = ["LOGGING", "QUERY", "ISOLATED"]

    static let teradataStatisticsWords: Set<String> = ["STATISTICS", "STATS", "STAT", "SUMMARY"]

    static let teradataSessionSettings: Set<String> = ["SESSION", "ROLE", "TIME", "TRANSFORM"]

    // SET QUERY_BAND ... FOR TRANSACTION is DML and FOR SESSION is DDL, and the FOR clause follows the band.
    static func queryBandScope(_ cursor: inout SQLTokenCursor) -> String? {
        var scope: String?
        while let token = cursor.next() {
            guard token.word == "FOR", cursor.parenDepth == 0 else { continue }
            scope = cursor.next()?.word
        }
        return scope
    }
}
