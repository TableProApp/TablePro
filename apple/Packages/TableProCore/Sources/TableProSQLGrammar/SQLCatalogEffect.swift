import Foundation

public struct SQLCatalogObjectKinds: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let tables = SQLCatalogObjectKinds(rawValue: 1 << 0)
    public static let routines = SQLCatalogObjectKinds(rawValue: 1 << 1)
    public static let triggers = SQLCatalogObjectKinds(rawValue: 1 << 2)
    public static let types = SQLCatalogObjectKinds(rawValue: 1 << 3)
    public static let schemas = SQLCatalogObjectKinds(rawValue: 1 << 4)
    public static let databases = SQLCatalogObjectKinds(rawValue: 1 << 5)

    public static let objects: SQLCatalogObjectKinds = [.tables, .routines, .triggers, .types]
    public static let everything: SQLCatalogObjectKinds = [.objects, .schemas, .databases]
}

public struct SQLCatalogEffect: Sendable, Equatable {
    public let kinds: SQLCatalogObjectKinds
    public let endsTransaction: Bool
    // Set apart from `kinds`: a CREATE DATABASE refreshes every kind too, yet the text says all it does.
    public let runsUnseenStatements: Bool

    public init(kinds: SQLCatalogObjectKinds, endsTransaction: Bool, runsUnseenStatements: Bool = false) {
        self.kinds = kinds
        self.endsTransaction = endsTransaction
        self.runsUnseenStatements = runsUnseenStatements
    }

    public static let none = SQLCatalogEffect(kinds: [], endsTransaction: false)

    // A procedure or a block may create or drop anything, so what the text cannot show refreshes every kind.
    public static let opaque = SQLCatalogEffect(kinds: .everything, endsTransaction: false, runsUnseenStatements: true)

    public func union(_ other: SQLCatalogEffect) -> SQLCatalogEffect {
        SQLCatalogEffect(
            kinds: kinds.union(other.kinds),
            endsTransaction: endsTransaction || other.endsTransaction,
            runsUnseenStatements: runsUnseenStatements || other.runsUnseenStatements
        )
    }
}

// No engine reports DDL reliably (MySQL says nothing, PostgreSQL tags CREATE TABLE AS as SELECT n), so the text
// decides, and errs toward refreshing: a missed refresh leaves a list naming objects that are gone.
public enum SQLCatalogEffectClassifier {
    private static let classifiedPrefixLength = 65_536
    private static let definitionNounWindow = 10

    public static func effect(ofStatements statements: [String], grammar: SQLLexicalGrammar) -> SQLCatalogEffect {
        statements.reduce(SQLCatalogEffect.none) { partial, statement in
            partial.union(effect(of: statement, grammar: grammar))
        }
    }

    public static func effect(of sql: String, grammar: SQLLexicalGrammar) -> SQLCatalogEffect {
        let trimmed = StatementBlank.trimming(SQLLeadingComments.stripping(sql))
        guard !trimmed.isEmpty else { return .none }
        if SQLProceduralBlock.runs(trimmed, grammar: grammar) {
            return .opaque
        }
        let tokens = leadingTokens(of: trimmed, grammar: grammar)
        let leading = leadingKeywordEffect(tokens: tokens, trimmed: trimmed)
        guard leading.kinds.isEmpty else { return leading }
        return leading.union(embeddedDefinitionEffect(tokens: tokens))
    }

    // SQL Server runs a batch as one statement, so a definition after its first command still counts.
    private static func embeddedDefinitionEffect(tokens: [String]) -> SQLCatalogEffect {
        guard let index = tokens.dropFirst().firstIndex(where: { embeddedDefinitionKeywords.contains($0) }) else {
            return .none
        }
        if embeddedExecutionKeywords.contains(tokens[index]) {
            return .opaque
        }
        return SQLCatalogEffect(kinds: definedKinds(after: tokens[(index + 1)...]), endsTransaction: false)
    }

    private static func leadingKeywordEffect(tokens: [String], trimmed: String) -> SQLCatalogEffect {
        guard let keyword = tokens.first else { return .none }

        if transactionEndKeywords.contains(keyword) {
            let rollsBackToSavepoint = keyword == "ROLLBACK" && tokens.dropFirst().prefix(2).contains("TO")
            return rollsBackToSavepoint ? .none : SQLCatalogEffect(kinds: [], endsTransaction: true)
        }
        if definitionKeywords.contains(keyword) {
            return SQLCatalogEffect(kinds: definedKinds(after: tokens.dropFirst()), endsTransaction: false)
        }
        if readKeywords.contains(keyword) {
            return SQLCatalogEffect(kinds: containsIntoClause(trimmed) ? .tables : [], endsTransaction: false)
        }
        if keyword == "BEGIN" {
            return beginsTransaction(tokens.dropFirst()) ? .none : .opaque
        }
        if attachKeywords.contains(keyword) {
            return SQLCatalogEffect(kinds: .everything, endsTransaction: false)
        }
        if rowKeywords.contains(keyword) || quietKeywords.contains(keyword) {
            return .none
        }
        return .opaque
    }

    private static func definedKinds(after tokens: ArraySlice<String>) -> SQLCatalogObjectKinds {
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

    // An executable comment is revealed without its version: /*!50001 CREATE VIEW */ reads as CREATE VIEW.
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

    private static let transactionEndKeywords: Set<String> = ["COMMIT", "END", "ROLLBACK", "ABORT"]

    private static let definitionKeywords: Set<String> = [
        "CREATE", "DROP", "ALTER", "RENAME", "COMMENT", "DEFINE", "REMOVE", "MSCK"
    ]

    private static let readKeywords: Set<String> = ["SELECT", "WITH", "TABLE", "VALUES"]

    private static let attachKeywords: Set<String> = ["ATTACH", "DETACH"]

    // Never an unquoted column name, so reading a `comment` or `remove` column refreshes nothing.
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

    private static let nounKinds: [String: SQLCatalogObjectKinds] = [
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

// A MySQL executable comment (/*! and /*M!) is code, so it is never skipped.
public enum SQLLeadingComments {
    public static let conditionalCommentOpeners: [String] = ["/*!", "/*M!"]

    public static let lineCommentTerminators: Set<Character> = ["\n", "\r", "\r\n"]

    public static func stripping(_ sql: String) -> String {
        var remaining = sql[...]
        while true {
            let trimmed = StatementBlank.trimmingLeading(remaining)
            if trimmed.hasPrefix("--") {
                guard let lineBreak = trimmed.firstIndex(where: endsLineComment) else { return "" }
                remaining = trimmed[trimmed.index(after: lineBreak)...]
            } else if trimmed.hasPrefix("/*"), !startsConditionalComment(trimmed) {
                guard let close = trimmed.range(of: "*/") else { return "" }
                remaining = trimmed[close.upperBound...]
            } else {
                return String(trimmed)
            }
        }
    }

    public static func startsConditionalComment(_ text: Substring) -> Bool {
        conditionalCommentOpeners.contains { text.hasPrefix($0) }
    }

    public static func endsLineComment(_ character: Character) -> Bool {
        lineCommentTerminators.contains(character)
    }

    public static func leadingCodeKeyword(_ code: String) -> String {
        let remaining = code.drop { StatementBlank.isBlank($0) || $0 == "(" }
        return remaining.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }
}

public enum SQLProceduralBlock {
    public static func runs(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        runsPLSQL(sql, grammar: grammar) || runsSQLScriptBlock(sql, grammar: grammar)
    }

    public static func runsPLSQL(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        guard grammar.contains(.plsqlBlocks) else { return false }
        return startsPLSQL(SQLCodeProjection.code(of: sql, grammar: grammar))
    }

    public static func runsSQLScriptBlock(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        guard grammar.contains(.sqlScriptBlocks) else { return false }
        return SQLLeadingComments.leadingCodeKeyword(SQLCodeProjection.code(of: sql, grammar: grammar)) == "DO"
    }

    // A block may open after <<label>> prefixes; a WITH clause declaring a FUNCTION or PROCEDURE runs PL/SQL too.
    public static func startsPLSQL(_ sql: String) -> Bool {
        var head = SQLLeadingComments.stripping(sql)
        while head.hasPrefix("<<") {
            guard let close = head.range(of: ">>") else { return false }
            head = SQLLeadingComments.stripping(String(head[close.upperBound...]))
        }
        let keyword = leadingWord(of: head)
        if keyword == "DECLARE" || keyword == "BEGIN" { return true }
        guard keyword == "WITH" else { return false }
        let declaration = leadingWord(of: SQLLeadingComments.stripping(String(head.dropFirst(keyword.count))))
        return declaration == "FUNCTION" || declaration == "PROCEDURE"
    }

    private static func leadingWord(of text: String) -> String {
        text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }
}
