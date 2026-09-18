//
//  AutocommitOnlyStatement+PostgreSQL.swift
//  TablePro
//

import Foundation

internal extension AutocommitOnlyStatement {
    /// PostgreSQL 17.11, each statement run after `BEGIN`. Redshift and CockroachDB take the
    /// PostgreSQL rules plus their own: Redshift's from the `SVL_MULTI_STATEMENT_VIOLATIONS` page,
    /// CockroachDB's measured on v25.2.23. `GRANT` and `COPY` are deliberately left out of the
    /// Redshift set: both are routinely run inside transactions and the page does not say which
    /// forms it means.
    static func matchesPostgresFamily(
        _ statement: NSString,
        family: TransactionEngineFamily,
        rules: SQLLexicalRules
    ) -> Bool {
        var cursor = SQLTokenCursor(statement, rules: rules)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "VACUUM":
            return true
        case "CLUSTER":
            return clustersEveryRelation(&cursor)
        case "REINDEX":
            return reindexesOutsideATransaction(&cursor)
        case "DISCARD":
            return cursor.next()?.word == "ALL"
        case "COMMIT", "ROLLBACK":
            return cursor.next()?.word == "PREPARED"
        case "CREATE":
            return creates(&cursor, family: family)
        case "DROP":
            return drops(&cursor, family: family)
        case "ALTER":
            return alters(&cursor, family: family)
        case "SET":
            return family == .cockroach && cursor.next()?.word == "CLUSTER" && cursor.next()?.word == "SETTING"
        case "BACKUP", "RESTORE", "IMPORT":
            return family == .cockroach && !mentions("DETACHED", in: &cursor)
        default:
            return false
        }
    }
}

private extension AutocommitOnlyStatement {
    struct StatementOption {
        let name: String
        let value: String?

        var isOn: Bool {
            guard let value else { return true }
            return !offValues.contains(value)
        }
    }

    static let offValues: Set<String> = ["FALSE", "OFF", "0"]

    static func creates(_ cursor: inout SQLTokenCursor, family: TransactionEngineFamily) -> Bool {
        guard let object = cursor.next()?.word else { return false }
        switch object {
        case "DATABASE", "TABLESPACE":
            return true
        case "SUBSCRIPTION":
            return !subscriptionSkipsTheServer(&cursor)
        case "UNIQUE":
            return cursor.next()?.word == "INDEX" && cursor.next()?.word == "CONCURRENTLY"
        case "INDEX":
            return cursor.next()?.word == "CONCURRENTLY"
        case "EXTERNAL":
            return family == .redshift && cursor.next()?.word == "TABLE"
        case "LIBRARY":
            return family == .redshift
        case "OR":
            return family == .redshift && cursor.next()?.word == "REPLACE" && cursor.next()?.word == "LIBRARY"
        default:
            return false
        }
    }

    static func drops(_ cursor: inout SQLTokenCursor, family: TransactionEngineFamily) -> Bool {
        guard let object = cursor.next()?.word else { return false }
        switch object {
        case "DATABASE", "TABLESPACE", "SUBSCRIPTION":
            return true
        case "INDEX":
            return cursor.next()?.word == "CONCURRENTLY"
        case "EXTERNAL":
            return family == .redshift && cursor.next()?.word == "TABLE"
        case "LIBRARY":
            return family == .redshift
        default:
            return false
        }
    }

    static func alters(_ cursor: inout SQLTokenCursor, family: TransactionEngineFamily) -> Bool {
        guard let object = cursor.next()?.word else { return false }
        switch object {
        case "SYSTEM":
            return true
        case "DATABASE":
            return cursor.next()?.identifier != nil
                && cursor.next()?.word == "SET"
                && cursor.next()?.word == "TABLESPACE"
        case "SUBSCRIPTION":
            return altersSubscriptionOutsideATransaction(&cursor)
        case "TYPE":
            return mentionsSequence(["ADD", "VALUE"], in: &cursor)
        case "TABLE":
            return detachesAPartitionConcurrently(&cursor, family: family)
        case "EXTERNAL":
            return family == .redshift && cursor.next()?.word == "TABLE"
        default:
            return false
        }
    }

    /// `ALTER TABLE p DETACH PARTITION p1 CONCURRENTLY` answers "ALTER TABLE ... DETACH
    /// CONCURRENTLY cannot run inside a transaction block"; the same statement without
    /// `CONCURRENTLY` is fine. Redshift's `ALTER TABLE t APPEND FROM s` is restricted whole.
    static func detachesAPartitionConcurrently(
        _ cursor: inout SQLTokenCursor,
        family: TransactionEngineFamily
    ) -> Bool {
        while let token = cursor.next() {
            guard cursor.parenDepth == 0, let word = token.word else { continue }
            if family == .redshift, word == "APPEND" { return true }
            guard word == "DETACH", cursor.next()?.word == "PARTITION" else { continue }
            guard cursor.next()?.identifier != nil else { return false }
            return cursor.next()?.word == "CONCURRENTLY"
        }
        return false
    }

    /// `CREATE SUBSCRIPTION` connects to the publisher and creates a replication slot unless it is
    /// told not to, and either of those is what it cannot do inside a transaction block.
    static func subscriptionSkipsTheServer(_ cursor: inout SQLTokenCursor) -> Bool {
        let options = withOptions(in: &cursor)
        return options.contains { ($0.name == "CONNECT" || $0.name == "CREATE_SLOT") && !$0.isOn }
    }

    static func altersSubscriptionOutsideATransaction(_ cursor: inout SQLTokenCursor) -> Bool {
        guard cursor.next()?.identifier != nil, let action = cursor.next()?.word else { return false }
        switch action {
        case "REFRESH":
            return true
        case "ADD", "DROP":
            return cursor.next()?.word == "PUBLICATION" && refreshesThePublisher(&cursor)
        case "SET":
            return setsPublicationOrFailover(&cursor)
        default:
            return false
        }
    }

    static func setsPublicationOrFailover(_ cursor: inout SQLTokenCursor) -> Bool {
        guard let token = cursor.next() else { return false }
        if token.isSymbol(SQLTokenCursor.openParen) {
            return readOptions(in: &cursor).contains { $0.name == "FAILOVER" }
        }
        return token.word == "PUBLICATION" && refreshesThePublisher(&cursor)
    }

    static func refreshesThePublisher(_ cursor: inout SQLTokenCursor) -> Bool {
        !withOptions(in: &cursor).contains { $0.name == "REFRESH" && !$0.isOn }
    }

    /// `REINDEX SCHEMA`, `DATABASE` and `SYSTEM` are refused whole; `INDEX` and `TABLE` only with
    /// `CONCURRENTLY`, spelled either as the keyword or as an option that is not turned off.
    static func reindexesOutsideATransaction(_ cursor: inout SQLTokenCursor) -> Bool {
        var token = cursor.next()
        if token?.isSymbol(SQLTokenCursor.openParen) == true {
            if readOptions(in: &cursor).contains(where: { $0.name == "CONCURRENTLY" && $0.isOn }) {
                return true
            }
            token = cursor.next()
        }
        guard let object = token?.word else { return false }
        if ["SCHEMA", "DATABASE", "SYSTEM"].contains(object) { return true }
        guard object == "INDEX" || object == "TABLE" else { return false }
        return cursor.next()?.word == "CONCURRENTLY"
    }

    /// A bare `CLUSTER`, with or without `VERBOSE`, clusters every table that has ever been
    /// clustered. Naming one keeps the wrap, and whether the server then refuses it depends on the
    /// catalog rather than on the text.
    static func clustersEveryRelation(_ cursor: inout SQLTokenCursor) -> Bool {
        while let token = cursor.next() {
            if token.isSymbol(SQLTokenCursor.openParen) {
                skipToEndOfOptions(&cursor)
                continue
            }
            guard token.word == "VERBOSE" else { return false }
        }
        return true
    }

    static func withOptions(in cursor: inout SQLTokenCursor) -> [StatementOption] {
        while let token = cursor.next() {
            guard cursor.parenDepth == 0, token.word == "WITH" else { continue }
            guard cursor.next()?.isSymbol(SQLTokenCursor.openParen) == true else { continue }
            return readOptions(in: &cursor)
        }
        return []
    }

    /// Reads a parenthesised option list whose opening parenthesis the caller has consumed. An
    /// option is a name, optionally followed by a value with or without `=`.
    static func readOptions(in cursor: inout SQLTokenCursor) -> [StatementOption] {
        var options: [StatementOption] = []
        var name: String?
        var value: String?
        while let token = cursor.next() {
            if cursor.parenDepth == 0 { break }
            if token.isSymbol(SQLTokenCursor.comma) {
                if let name { options.append(StatementOption(name: name, value: value)) }
                name = nil
                value = nil
                continue
            }
            if token.isSymbol(SQLTokenCursor.equals) { continue }
            guard let word = token.identifier else { continue }
            if name == nil {
                name = word
            } else if value == nil {
                value = word
            }
        }
        if let name { options.append(StatementOption(name: name, value: value)) }
        return options
    }

    static func skipToEndOfOptions(_ cursor: inout SQLTokenCursor) {
        while cursor.parenDepth > 0, cursor.next() != nil {}
    }

    static func mentions(_ word: String, in cursor: inout SQLTokenCursor) -> Bool {
        while let token = cursor.next() {
            if token.word == word { return true }
        }
        return false
    }

    static func mentionsSequence(_ words: [String], in cursor: inout SQLTokenCursor) -> Bool {
        guard let first = words.first else { return false }
        while let token = cursor.next() {
            guard cursor.parenDepth == 0, token.word == first else { continue }
            guard words.dropFirst().allSatisfy({ cursor.next()?.word == $0 }) else { continue }
            return true
        }
        return false
    }
}
