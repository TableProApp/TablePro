//
//  SQLTokenizer.swift
//  TablePro
//
//  Character-by-character SQL lexer producing a flat token stream.
//  No regex — handles string escapes, comments, operators, and quoted identifiers.
//

import Foundation

// MARK: - Token Types

enum SQLTokenType: Equatable {
    case keyword
    case identifier
    case number
    case string
    case `operator`
    case punctuation
    case whitespace
    case comment
    case placeholder
}

// MARK: - Token

struct SQLToken: Equatable {
    let type: SQLTokenType
    let value: String
    /// Pre-computed uppercase value for keyword comparison
    let upperValue: String

    init(type: SQLTokenType, value: String) {
        self.type = type
        self.value = value
        self.upperValue = value.uppercased()
    }
}

// MARK: - Tokenizer

struct SQLTokenizer {
    /// Standard SQL keywords used for keyword detection.
    /// Dialect-specific keywords are handled separately via SQLDialectProvider.
    private static let standardKeywords: Set<String> = [
        // DML
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
        "LIKE", "BETWEEN", "EXISTS", "AS", "ON", "USING",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "NATURAL",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",
        "UNION", "INTERSECT", "EXCEPT", "ALL", "DISTINCT",
        // CASE
        "CASE", "WHEN", "THEN", "ELSE", "END",
        // DDL
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
        "ADD", "COLUMN", "CONSTRAINT", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "UNIQUE", "CHECK", "DEFAULT", "AUTO_INCREMENT", "IDENTITY",
        "IF", "TEMPORARY", "TEMP", "CASCADE", "RESTRICT",
        // CTE
        "WITH", "RECURSIVE",
        // Data types
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
        "VARCHAR", "CHAR", "TEXT", "NVARCHAR", "NCHAR",
        "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
        "BOOLEAN", "BOOL", "BIT",
        "DATE", "TIME", "TIMESTAMP", "DATETIME", "INTERVAL",
        "BLOB", "CLOB", "BINARY", "VARBINARY",
        "JSON", "JSONB", "XML", "UUID",
        "SERIAL", "BIGSERIAL",
        // Aggregates
        "COUNT", "SUM", "AVG", "MIN", "MAX",
        // Transaction
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",
        // Other
        "ASC", "DESC", "NULLS", "FIRST", "LAST",
        "TRUE", "FALSE", "UNKNOWN",
        "OVER", "PARTITION", "WINDOW", "FILTER",
        "RETURNING", "CONFLICT", "DO", "NOTHING",
        "EXPLAIN", "ANALYZE", "TRUNCATE",
        "GRANT", "REVOKE", "DENY",
        "TOP", "PERCENT",
    ]

    /// Additional keywords from the dialect provider
    private let dialectKeywords: Set<String>

    init(dialectKeywords: Set<String> = []) {
        self.dialectKeywords = dialectKeywords
    }

    // MARK: - Public API

    func tokenize(_ sql: String) -> [SQLToken] {
        var tokens: [SQLToken] = []
        let chars = Array(sql)
        let count = chars.count
        var i = 0

        while i < count {
            let ch = chars[i]

            // Line comment: -- ...
            if ch == "-" && i + 1 < count && chars[i + 1] == "-" {
                let start = i
                i += 2
                while i < count && chars[i] != "\n" {
                    i += 1
                }
                tokens.append(SQLToken(type: .comment, value: String(chars[start..<i])))
                continue
            }

            // Block comment: /* ... */
            if ch == "/" && i + 1 < count && chars[i + 1] == "*" {
                let start = i
                i += 2
                while i + 1 < count && !(chars[i] == "*" && chars[i + 1] == "/") {
                    i += 1
                }
                if i + 1 < count {
                    i += 2 // skip */
                }
                tokens.append(SQLToken(type: .comment, value: String(chars[start..<i])))
                continue
            }

            // String literals: 'single', "double", `backtick`
            if ch == "'" || ch == "\"" || ch == "`" {
                let start = i
                let quote = ch
                i += 1
                while i < count {
                    if chars[i] == "\\" {
                        i += 2 // skip escaped char
                        continue
                    }
                    if chars[i] == quote {
                        // Check for doubled quote escape: '' or ""
                        if i + 1 < count && chars[i + 1] == quote {
                            i += 2
                            continue
                        }
                        i += 1
                        break
                    }
                    i += 1
                }
                let value = String(chars[start..<i])
                // Backtick-quoted identifiers are identifiers, not strings
                let type: SQLTokenType = (quote == "`") ? .identifier : .string
                tokens.append(SQLToken(type: type, value: value))
                continue
            }

            // Whitespace
            if ch.isWhitespace {
                let start = i
                while i < count && chars[i].isWhitespace {
                    i += 1
                }
                tokens.append(SQLToken(type: .whitespace, value: String(chars[start..<i])))
                continue
            }

            // Numbers
            if ch.isNumber || (ch == "." && i + 1 < count && chars[i + 1].isNumber) {
                let start = i
                if ch == "." { i += 1 }
                while i < count && (chars[i].isNumber || chars[i] == ".") {
                    i += 1
                }
                // Scientific notation: 1e10, 1.5E-3
                if i < count && (chars[i] == "e" || chars[i] == "E") {
                    i += 1
                    if i < count && (chars[i] == "+" || chars[i] == "-") {
                        i += 1
                    }
                    while i < count && chars[i].isNumber {
                        i += 1
                    }
                }
                tokens.append(SQLToken(type: .number, value: String(chars[start..<i])))
                continue
            }

            // Placeholders: $1, $name, ?, :name, @name
            if ch == "?" {
                tokens.append(SQLToken(type: .placeholder, value: "?"))
                i += 1
                continue
            }
            if (ch == "$" || ch == ":" || ch == "@") && i + 1 < count && (chars[i + 1].isLetter || chars[i + 1].isNumber || chars[i + 1] == "_") {
                let start = i
                i += 1
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                tokens.append(SQLToken(type: .placeholder, value: String(chars[start..<i])))
                continue
            }

            // Multi-character operators: >=, <=, <>, !=, ||, ::, ->>, ->
            if i + 1 < count {
                let twoChar = String([chars[i], chars[i + 1]])
                if [">=", "<=", "<>", "!=", "||", "::", "->"].contains(twoChar) {
                    if twoChar == "->" && i + 2 < count && chars[i + 2] == ">" {
                        tokens.append(SQLToken(type: .operator, value: "->>"))
                        i += 3
                    } else {
                        tokens.append(SQLToken(type: .operator, value: twoChar))
                        i += 2
                    }
                    continue
                }
            }

            // Single-character operators
            if "=<>+-*/%&|^~!".contains(ch) {
                tokens.append(SQLToken(type: .operator, value: String(ch)))
                i += 1
                continue
            }

            // Punctuation: ( ) , ; .
            if "(),;.".contains(ch) {
                tokens.append(SQLToken(type: .punctuation, value: String(ch)))
                i += 1
                continue
            }

            // Words: keywords or identifiers
            if ch.isLetter || ch == "_" {
                let start = i
                i += 1
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let word = String(chars[start..<i])
                let isKW = Self.standardKeywords.contains(word.uppercased())
                    || dialectKeywords.contains(word.uppercased())
                tokens.append(SQLToken(type: isKW ? .keyword : .identifier, value: word))
                continue
            }

            // Unknown character — treat as operator
            tokens.append(SQLToken(type: .operator, value: String(ch)))
            i += 1
        }

        return tokens
    }
}
