//
//  SQLClientEncodingRewriter.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

internal enum SQLClientEncodingRewriter {
    private struct Replacement {
        let range: NSRange
        let text: String
    }

    private static let mysqlSessionCharacterSet = "@@session.character_set_client"
    private static let mysqlKeepSessionCharacterSet = "character_set_client = @@session.character_set_client"
    private static let postgresEncoding = "'UTF8'"
    private static let unicodeSpellings: Set<String> = ["UTF8", "UTF8MB4", "UTF8MB3", "UNICODE"]
    private static let mysqlSessionScopes: Set<String> = ["SESSION", "LOCAL"]
    private static let mysqlServerScopes: Set<String> = ["GLOBAL", "PERSIST", "PERSIST_ONLY"]
    private static let postgresScopes: Set<String> = ["SESSION", "LOCAL"]
    private static let clientCharacterSetVariable = "CHARACTER_SET_CLIENT"

    internal static func rewritten(
        _ statement: String,
        family: TransactionEngineFamily,
        grammar: SQLLexicalGrammar
    ) -> String? {
        let text = statement as NSString
        var cursor = SQLTokenCursor(text, grammar: grammar)
        guard cursor.next()?.word == "SET" else { return nil }
        let replacements: [Replacement]
        switch family {
        case .mysql:
            replacements = mysqlClientCharacterSets(&cursor, in: text)
        case .postgres, .redshift, .cockroach:
            replacements = postgresClientEncoding(&cursor, in: text).map { [Replacement(range: $0, text: postgresEncoding)] } ?? []
        case .sqlite, .duckdb, .sqlServer, .oracle, .redis, .other:
            return nil
        }
        guard !replacements.isEmpty else { return nil }
        let result = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return result as String
    }

    private static func mysqlClientCharacterSets(_ cursor: inout SQLTokenCursor, in text: NSString) -> [Replacement] {
        var replacements: [Replacement] = []
        var listIsServerScoped = false
        var head = cursor.next()
        while let token = head {
            if let replacement = mysqlDeclaration(
                startingAt: token,
                cursor: &cursor,
                in: text,
                listIsServerScoped: &listIsServerScoped
            ) {
                replacements.append(replacement)
            }
            head = nextElementHead(&cursor)
        }
        return replacements
    }

    private static func mysqlDeclaration(
        startingAt token: SQLTokenCursor.Token,
        cursor: inout SQLTokenCursor,
        in text: NSString,
        listIsServerScoped: inout Bool
    ) -> Replacement? {
        var current = token
        while let word = current.word, mysqlSessionScopes.contains(word) || mysqlServerScopes.contains(word) {
            listIsServerScoped = mysqlServerScopes.contains(word)
            guard let next = cursor.next() else { return nil }
            current = next
        }
        let elementStart = cursor.tokenRange.location
        switch current.word {
        case "NAMES":
            return characterSetValue(&cursor, in: text, allowsCollation: true).map {
                Replacement(range: range(from: elementStart, through: $0), text: mysqlKeepSessionCharacterSet)
            }
        case "CHARSET":
            return characterSetValue(&cursor, in: text, allowsCollation: false).map {
                Replacement(range: range(from: elementStart, through: $0), text: mysqlKeepSessionCharacterSet)
            }
        case "CHARACTER":
            guard cursor.next()?.word == "SET" else { return nil }
            return characterSetValue(&cursor, in: text, allowsCollation: false).map {
                Replacement(range: range(from: elementStart, through: $0), text: mysqlKeepSessionCharacterSet)
            }
        default:
            guard let isSessionVariable = clientCharacterSetVariableScope(current, cursor: &cursor),
                  isSessionVariable || !listIsServerScoped,
                  cursor.next()?.isSymbol(SQLTokenCursor.equals) == true else {
                return nil
            }
            return characterSetValue(&cursor, in: text, allowsCollation: false).map {
                Replacement(range: $0, text: mysqlSessionCharacterSet)
            }
        }
    }

    private static func clientCharacterSetVariableScope(
        _ token: SQLTokenCursor.Token,
        cursor: inout SQLTokenCursor
    ) -> Bool? {
        guard let name = token.identifier else { return nil }
        switch name {
        case clientCharacterSetVariable:
            return false
        case "@@" + clientCharacterSetVariable:
            return true
        case "@@SESSION", "@@LOCAL":
            guard cursor.next()?.isSymbol(SQLTokenCursor.period) == true,
                  cursor.next()?.identifier == clientCharacterSetVariable else {
                return nil
            }
            return true
        default:
            return nil
        }
    }

    private static func postgresClientEncoding(_ cursor: inout SQLTokenCursor, in text: NSString) -> NSRange? {
        guard var token = cursor.next() else { return nil }
        if let word = token.word, postgresScopes.contains(word) {
            guard let next = cursor.next() else { return nil }
            token = next
        }
        switch token.identifier {
        case "CLIENT_ENCODING":
            guard let separator = cursor.next(),
                  separator.isSymbol(SQLTokenCursor.equals) || separator.word == "TO" else {
                return nil
            }
            return characterSetValue(&cursor, in: text, allowsCollation: false)
        case "NAMES":
            return characterSetValue(&cursor, in: text, allowsCollation: false)
        default:
            return nil
        }
    }

    private static func characterSetValue(
        _ cursor: inout SQLTokenCursor,
        in text: NSString,
        allowsCollation: Bool
    ) -> NSRange? {
        guard let value = cursor.next() else { return nil }
        let valueRange = cursor.tokenRange
        guard let name = characterSetName(of: value, range: valueRange, in: text),
              !unicodeSpellings.contains(normalized(name)) else {
            return nil
        }
        guard allowsCollation else { return valueRange }
        var lookahead = cursor
        guard lookahead.next()?.word == "COLLATE", lookahead.next() != nil else { return valueRange }
        cursor = lookahead
        return NSRange(location: valueRange.location, length: cursor.location - valueRange.location)
    }

    private static func range(from start: Int, through end: NSRange) -> NSRange {
        NSRange(location: start, length: NSMaxRange(end) - start)
    }

    private static func characterSetName(of token: SQLTokenCursor.Token, range: NSRange, in text: NSString) -> String? {
        switch token {
        case .word(let word):
            guard word != "DEFAULT", !word.hasPrefix("@"), let first = word.unicodeScalars.first,
                  !CharacterSet.decimalDigits.contains(first) else {
                return nil
            }
            return word
        case .quotedIdentifier(let name):
            return name
        case .literal:
            guard range.length >= 2 else { return nil }
            return text.substring(with: NSRange(location: range.location + 1, length: range.length - 2))
        case .symbol:
            return nil
        }
    }

    private static func normalized(_ name: String) -> String {
        String(name.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func nextElementHead(_ cursor: inout SQLTokenCursor) -> SQLTokenCursor.Token? {
        while let token = cursor.next() {
            if token.isSymbol(SQLTokenCursor.comma), cursor.parenDepth == 0 {
                return cursor.next()
            }
        }
        return nil
    }
}
