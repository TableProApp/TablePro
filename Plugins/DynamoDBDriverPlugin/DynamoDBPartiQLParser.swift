//
//  DynamoDBPartiQLParser.swift
//  DynamoDBDriverPlugin
//
//  Lightweight PartiQL statement classifier.
//

import Foundation

enum DynamoDBQueryType {
    case select
    case insert
    case update
    case delete
    case unknown
}

struct DynamoDBPartiQLParser {
    /// Classify a PartiQL statement by its first keyword.
    static func queryType(_ statement: String) -> DynamoDBQueryType {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = trimmed.components(separatedBy: .whitespacesAndNewlines).first?.uppercased() ?? ""

        switch firstWord {
        case "SELECT":
            return .select
        case "INSERT":
            return .insert
        case "UPDATE":
            return .update
        case "DELETE":
            return .delete
        default:
            return .unknown
        }
    }

    /// Extract the table name from a PartiQL statement.
    /// Handles quoted ("TableName") and unquoted table names.
    ///
    /// Patterns:
    /// - SELECT ... FROM "TableName" ...
    /// - INSERT INTO "TableName" ...
    /// - UPDATE "TableName" ...
    /// - DELETE FROM "TableName" ...
    static func extractTableName(_ statement: String) -> String? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = tokenize(trimmed)

        guard !tokens.isEmpty else { return nil }

        let firstUpper = tokens[0].uppercased()

        switch firstUpper {
        case "SELECT":
            // Find FROM keyword and take the next token
            if let fromIndex = tokens.firstIndex(where: { $0.uppercased() == "FROM" }),
               fromIndex + 1 < tokens.count
            {
                return normalizeIdentifierToken(tokens[fromIndex + 1])
            }
        case "INSERT":
            // INSERT INTO "table" ...
            if tokens.count >= 3, tokens[1].uppercased() == "INTO" {
                return normalizeIdentifierToken(tokens[2])
            }
        case "UPDATE":
            // UPDATE "table" ...
            if tokens.count >= 2 {
                return normalizeIdentifierToken(tokens[1])
            }
        case "DELETE":
            // DELETE FROM "table" ...
            if tokens.count >= 3, tokens[1].uppercased() == "FROM" {
                return normalizeIdentifierToken(tokens[2])
            }
        default:
            break
        }

        return nil
    }

    // MARK: - Private

    /// Simple tokenizer that respects quoted identifiers and string literals.
    private static func tokenize(_ sql: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inDoubleQuote = false
        var inSingleQuote = false
        var isEscaped = false

        for char in sql {
            if isEscaped {
                current.append(char)
                isEscaped = false
                continue
            }

            if char == "\\" {
                current.append(char)
                isEscaped = true
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(char)
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(char)
                continue
            }

            if char.isWhitespace && !inDoubleQuote && !inSingleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Strip trailing punctuation (`;`, `,`) from a token before unquoting.
    private static func normalizeIdentifierToken(_ token: String) -> String {
        var cleaned = token
        while cleaned.hasSuffix(";") || cleaned.hasSuffix(",") {
            cleaned = String(cleaned.dropLast())
        }
        return unquoteIdentifier(cleaned)
    }

    /// Remove surrounding double quotes from an identifier if present.
    private static func unquoteIdentifier(_ identifier: String) -> String {
        if identifier.hasPrefix("\"") && identifier.hasSuffix("\"") && identifier.count >= 2 {
            let inner = String(identifier.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\"\"", with: "\"")
        }
        return identifier
    }
}
