//
//  IndexKeyList.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

struct IndexKeyContext {
    let columnNames: [String]
    let dialect: IndexKeyDialect
    let grammar: SQLLexicalGrammar

    func column(named name: String) -> String? {
        columnNames.first { $0 == name }
            ?? columnNames.first { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }
}

enum IndexKeyPart: Equatable {
    case column(String)
    case prefixedColumn(String, length: Int)
    case expression(String)

    var entry: String {
        switch self {
        case .column(let name), .prefixedColumn(let name, _):
            return name
        case .expression(let text):
            return text
        }
    }
}

enum IndexKeyList {
    private static let sortOrderWords: Set<String> = ["ASC", "DESC"]
    private static let nullsPlacementWords: Set<String> = ["FIRST", "LAST"]

    static func parts(of text: String, keeping expressions: [String], in context: IndexKeyContext) -> [IndexKeyPart] {
        entries(of: text, keeping: expressions, in: context).map {
            classify($0, keeping: expressions, in: context)
        }
    }

    static func entries(of text: String, keeping expressions: [String], in context: IndexKeyContext) -> [String] {
        let knownNames = self.knownNames(expressions: expressions, columns: context.columnNames)
        var entries: [String] = []
        var remaining = text as NSString
        while remaining.length > 0 {
            let start = remaining.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted).location
            guard start != NSNotFound else { break }
            remaining = remaining.substring(from: start) as NSString
            let length = knownEntryLength(in: remaining, knownNames: knownNames)
                ?? codeEntryLength(in: remaining, grammar: context.grammar)
            entries.append(remaining.substring(to: length).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining.substring(from: min(length + 1, remaining.length)) as NSString
        }
        return entries.filter { !$0.isEmpty }
    }

    private struct KnownName {
        let text: String
        let ignoresCase: Bool
    }

    private static func knownNames(expressions: [String], columns: [String]) -> [KnownName] {
        let names = expressions.filter { !$0.isEmpty }.map { KnownName(text: $0, ignoresCase: false) }
            + columns.filter { !$0.isEmpty }.map { KnownName(text: $0, ignoresCase: true) }
        return names.sorted { ($0.text as NSString).length > ($1.text as NSString).length }
    }

    private static func knownEntryLength(in text: NSString, knownNames: [KnownName]) -> Int? {
        for name in knownNames {
            let options: NSString.CompareOptions = name.ignoresCase ? [.anchored, .caseInsensitive] : [.anchored]
            let match = text.range(of: name.text, options: options)
            guard match.location == 0 else { continue }
            let tail = text.substring(from: match.length) as NSString
            let next = tail.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
            guard next.location != NSNotFound else { return text.length }
            if tail.character(at: next.location) == SQLTokenCursor.comma {
                return match.length + next.location
            }
        }
        return nil
    }

    private static func codeEntryLength(in text: NSString, grammar: SQLLexicalGrammar) -> Int {
        var cursor = SQLTokenCursor(text, grammar: grammar)
        while let token = cursor.next() {
            if token.isSymbol(SQLTokenCursor.comma), cursor.parenDepth == 0 {
                return cursor.location - 1
            }
        }
        return text.length
    }

    private static func classify(
        _ entry: String,
        keeping expressions: [String],
        in context: IndexKeyContext
    ) -> IndexKeyPart {
        if expressions.contains(entry) { return .expression(entry) }
        if let column = context.column(named: entry) { return .column(column) }
        let scan = Scan(entry, grammar: context.grammar)
        if let name = scan.singleName { return .column(context.column(named: name) ?? name) }
        if let name = scan.parenthesizedName(in: entry) { return .column(context.column(named: name) ?? name) }
        if context.dialect.takesPrefixLengths, let prefix = scan.prefix(of: entry) {
            return .prefixedColumn(context.column(named: prefix.name) ?? prefix.name, length: prefix.length)
        }
        guard context.dialect.takesExpressions, scan.isWritableExpression,
              isPlainCode(entry, grammar: context.grammar) else { return .column(entry) }
        return .expression(entry)
    }

    private static func isPlainCode(_ entry: String, grammar: SQLLexicalGrammar) -> Bool {
        let text = entry as NSString
        var index = 0
        while index < text.length {
            guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) else {
                index += 1
                continue
            }
            guard span.kind == .quoted, span.isTerminated else { return false }
            index = max(span.end, index + 1)
        }
        return true
    }

    private struct Scan {
        private(set) var tokens: [SQLTokenCursor.Token] = []
        private(set) var isBalanced = true

        init(_ entry: String, grammar: SQLLexicalGrammar) {
            let text = entry as NSString
            var cursor = SQLTokenCursor(text, grammar: grammar)
            while true {
                let depth = cursor.parenDepth
                guard let token = cursor.next() else { break }
                if token.isSymbol(SQLTokenCursor.closeParen), depth == 0 { isBalanced = false }
                tokens.append(token)
            }
            isBalanced = isBalanced && cursor.parenDepth == 0 && cursor.location >= text.length
        }

        var singleName: String? {
            guard tokens.count == 1, case .quotedIdentifier(let name) = tokens[0] else { return nil }
            return name
        }

        func parenthesizedName(in entry: String) -> String? {
            guard tokens.count == 3, tokens[0].isSymbol(SQLTokenCursor.openParen),
                  tokens[2].isSymbol(SQLTokenCursor.closeParen) else { return nil }
            switch tokens[1] {
            case .word:
                return String(entry.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            case .quotedIdentifier(let name):
                return name
            case .literal, .symbol:
                return nil
            }
        }

        func prefix(of entry: String) -> (name: String, length: Int)? {
            guard tokens.count == 4, tokens[1].isSymbol(SQLTokenCursor.openParen),
                  let digits = tokens[2].word, let length = Int(digits), length > 0,
                  tokens[3].isSymbol(SQLTokenCursor.closeParen) else { return nil }
            switch tokens[0] {
            case .quotedIdentifier(let name):
                return (name, length)
            case .word:
                let name = entry.prefix { $0 != "(" }.trimmingCharacters(in: .whitespacesAndNewlines)
                return (name, length)
            case .literal, .symbol:
                return nil
            }
        }

        var isWritableExpression: Bool {
            isBalanced && tokens.count > 1 && !endsWithSortOrder
        }

        private var endsWithSortOrder: Bool {
            guard let last = tokens.last?.word else { return false }
            if IndexKeyList.sortOrderWords.contains(last) { return true }
            guard IndexKeyList.nullsPlacementWords.contains(last), tokens.count >= 2 else { return false }
            return tokens[tokens.count - 2].word == "NULLS"
        }
    }
}
