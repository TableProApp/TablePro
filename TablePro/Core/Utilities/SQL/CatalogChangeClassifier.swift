//
//  CatalogChangeClassifier.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

struct CatalogStatementEffect: Sendable, Equatable {
    let kinds: CatalogObjectKinds
    let endsTransaction: Bool

    static let none = CatalogStatementEffect(kinds: [], endsTransaction: false)

    func union(_ other: CatalogStatementEffect) -> CatalogStatementEffect {
        CatalogStatementEffect(
            kinds: kinds.union(other.kinds),
            endsTransaction: endsTransaction || other.endsTransaction
        )
    }
}

/// Which parts of the catalog a statement that ran may have changed.
///
/// No engine reports this reliably: MySQL and MariaDB say nothing for DDL, PostgreSQL tags
/// `CREATE TABLE AS` as `SELECT n` and hides DDL behind `DO` and `CALL`. So the text decides, and it
/// errs toward refreshing, because a refresh never clears what is on screen while a missed one is a
/// sidebar listing objects that are gone.
enum CatalogChangeClassifier {
    private static let classifiedPrefixLength = 65_536
    private static let definitionNounWindow = 10

    static func effect(ofStatements statements: [String], databaseType: DatabaseType) -> CatalogStatementEffect {
        statements.reduce(CatalogStatementEffect.none) { partial, statement in
            partial.union(effect(of: statement, databaseType: databaseType))
        }
    }

    static func effect(of sql: String, databaseType: DatabaseType) -> CatalogStatementEffect {
        let trimmed = StatementBlank.trimming(QueryClassifier.strippingLeadingComments(sql))
        guard !trimmed.isEmpty else { return .none }
        if databaseType == .redis {
            return .none
        }
        if documentStoreTypes.contains(databaseType) {
            let tier = QueryClassifier.classifyTier(trimmed, databaseType: databaseType)
            return tier == .safe ? .none : opaque
        }
        let grammar = databaseType.lexicalGrammar
        if QueryClassifier.runsPLSQL(trimmed, grammar: grammar) {
            return opaque
        }
        return sqlEffect(trimmed, grammar: grammar)
    }

    private static func sqlEffect(_ trimmed: String, grammar: SQLLexicalGrammar) -> CatalogStatementEffect {
        let tokens = leadingTokens(of: trimmed, grammar: grammar)
        let leading = leadingKeywordEffect(tokens: tokens, trimmed: trimmed)
        guard leading.kinds.isEmpty else { return leading }
        return leading.union(embeddedDefinitionEffect(tokens: tokens))
    }

    /// SQL Server runs a batch as one statement with no semicolons between its commands, so
    /// `SET NOCOUNT ON` or `BEGIN TRANSACTION` on the first line says nothing about a `CREATE TABLE`
    /// on the next. A definition keyword anywhere past the first token is read as one.
    private static func embeddedDefinitionEffect(tokens: [String]) -> CatalogStatementEffect {
        guard let index = tokens.dropFirst().firstIndex(where: { embeddedDefinitionKeywords.contains($0) }) else {
            return .none
        }
        if embeddedExecutionKeywords.contains(tokens[index]) {
            return opaque
        }
        return CatalogStatementEffect(kinds: definedKinds(after: tokens[(index + 1)...]), endsTransaction: false)
    }

    private static func leadingKeywordEffect(tokens: [String], trimmed: String) -> CatalogStatementEffect {
        guard let keyword = tokens.first else { return .none }

        if transactionEndKeywords.contains(keyword) {
            let rollsBackToSavepoint = keyword == "ROLLBACK" && tokens.dropFirst().prefix(2).contains("TO")
            return rollsBackToSavepoint ? .none : CatalogStatementEffect(kinds: [], endsTransaction: true)
        }
        if definitionKeywords.contains(keyword) {
            return CatalogStatementEffect(kinds: definedKinds(after: tokens.dropFirst()), endsTransaction: false)
        }
        if readKeywords.contains(keyword) {
            return CatalogStatementEffect(kinds: containsIntoClause(trimmed) ? .tables : [], endsTransaction: false)
        }
        if keyword == "BEGIN" {
            return beginsTransaction(tokens.dropFirst()) ? .none : opaque
        }
        if attachKeywords.contains(keyword) {
            return CatalogStatementEffect(kinds: .everything, endsTransaction: false)
        }
        if rowKeywords.contains(keyword) || quietKeywords.contains(keyword) {
            return .none
        }
        return opaque
    }

    /// A procedure, an anonymous block or a document store command can create or drop a schema or a
    /// whole database as easily as a table, so what the text cannot show refreshes every kind.
    private static let opaque = CatalogStatementEffect(kinds: .everything, endsTransaction: false)

    private static func definedKinds(after tokens: ArraySlice<String>) -> CatalogObjectKinds {
        for token in tokens.prefix(definitionNounWindow) {
            guard let kinds = nounKinds[token] else { continue }
            if principalNouns.contains(token) {
                return tokens.contains("CASCADE") ? [.schemas, .objects] : []
            }
            return kinds
        }
        return .objects
    }

    private static func beginsTransaction(_ tokens: ArraySlice<String>) -> Bool {
        guard let next = tokens.first else { return true }
        return transactionModifiers.contains(next)
    }

    /// Identifier tokens of the statement's opening, with MySQL executable comments revealed and
    /// their version numbers dropped, so `/*!50001 CREATE ... VIEW */` reads as `CREATE VIEW`.
    private static func leadingTokens(of trimmed: String, grammar: SQLLexicalGrammar) -> [String] {
        let prefix = String(trimmed.prefix(classifiedPrefixLength))
        let body = SQLCodeProjection.code(of: prefix, grammar: grammar, revealingExecutableComments: true).uppercased()
        var tokens: [String] = []
        var current = ""
        for character in body {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
                continue
            }
            appendToken(current, to: &tokens)
            current = ""
        }
        appendToken(current, to: &tokens)
        return tokens
    }

    private static func appendToken(_ token: String, to tokens: inout [String]) {
        guard !token.isEmpty, !token.allSatisfy(\.isNumber) else { return }
        tokens.append(token)
    }

    private static func containsIntoClause(_ sql: String) -> Bool {
        sql.range(of: #"\bINTO\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let documentStoreTypes: Set<DatabaseType> = [
        .mongodb, .elasticsearch, .typesense, .weaviate, .etcd
    ]

    private static let transactionEndKeywords: Set<String> = ["COMMIT", "END", "ROLLBACK", "ABORT"]

    private static let definitionKeywords: Set<String> = [
        "CREATE", "DROP", "ALTER", "RENAME", "COMMENT", "DEFINE", "REMOVE", "MSCK"
    ]

    private static let readKeywords: Set<String> = ["SELECT", "WITH", "TABLE", "VALUES"]

    private static let attachKeywords: Set<String> = ["ATTACH", "DETACH"]

    /// Only keywords that never name a column unquoted, so a query reading a `comment` or `remove`
    /// column does not refresh the catalog every time it runs.
    private static let embeddedDefinitionKeywords: Set<String> = ["CREATE", "DROP", "ALTER", "EXEC", "EXECUTE"]

    private static let embeddedExecutionKeywords: Set<String> = ["EXEC", "EXECUTE"]

    private static let rowKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT", "COPY", "LOAD", "TRUNCATE", "RELATE", "LET"
    ]

    private static let quietKeywords: Set<String> = [
        "SET", "RESET", "USE", "LOCK", "UNLOCK", "SAVEPOINT", "RELEASE", "PREPARE", "DEALLOCATE",
        "DECLARE", "FETCH", "CLOSE", "MOVE", "DISCARD", "LISTEN", "UNLISTEN", "NOTIFY",
        "VACUUM", "ANALYZE", "ANALYSE", "OPTIMIZE", "REPAIR", "CHECK", "REINDEX", "CLUSTER",
        "CHECKPOINT", "FLUSH", "KILL", "GRANT", "REVOKE", "DENY", "EXPLAIN", "SHOW", "DESCRIBE",
        "DESC", "HELP", "PRAGMA", "START", "INFO", "PRINT", "REFRESH", "PURGE", "SHUTDOWN"
    ]

    private static let transactionModifiers: Set<String> = [
        "TRANSACTION", "WORK", "TRAN", "DEFERRED", "IMMEDIATE", "EXCLUSIVE", "DISTRIBUTED", "ISOLATION", "READ"
    ]

    private static let principalNouns: Set<String> = ["USER", "ROLE", "LOGIN", "GROUP"]

    private static let nounKinds: [String: CatalogObjectKinds] = [
        "TABLE": .tables, "TABLES": .tables, "VIEW": .tables, "INDEX": .tables, "SEQUENCE": .tables,
        "PARTITION": .tables, "COLUMN": .tables, "CONSTRAINT": .tables, "COLLECTION": .tables,
        "SYNONYM": .tables, "FIELD": .tables,
        "FUNCTION": .routines, "PROCEDURE": .routines, "PROC": .routines, "ROUTINE": .routines,
        "AGGREGATE": .routines, "MACRO": .routines, "PACKAGE": .routines, "OPERATOR": .routines,
        "TRIGGER": .triggers, "EVENT": .triggers,
        "TYPE": .types, "DOMAIN": .types, "ENUM": .types,
        "SCHEMA": [.schemas, .objects], "NAMESPACE": [.schemas, .objects], "OWNED": [.schemas, .objects],
        "DATABASE": .everything, "KEYSPACE": .everything, "CATALOG": .everything,
        "EXTENSION": .objects,
        "USER": [], "ROLE": [], "LOGIN": [], "GROUP": []
    ]
}
