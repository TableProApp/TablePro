//
//  QueryTableReferenceResolver.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

struct QueryTableReference: Hashable, Sendable {
    let name: String
    let qualifiers: [String]

    init(name: String, qualifiers: [String] = []) {
        self.name = name
        self.qualifiers = qualifiers
    }

    var displayName: String {
        (qualifiers + [name]).joined(separator: ".")
    }
}

enum QueryTableReferenceResolver {
    static let scanLimit = 20_000

    static func sqlReferences(in statement: String, grammar: SQLLexicalGrammar) -> [QueryTableReference] {
        let tokens = QueryTokenScanner.tokens(in: scannedText(statement), grammar: grammar)
        var parser = QueryReferenceParser(tokens: tokens)
        return parser.references()
    }

    static func identifierTokens(in text: String) -> [String] {
        let tokens = QueryTokenScanner.tokens(in: scannedText(text), grammar: .ansi, literalsAsIdentifiers: true)
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            guard let identifier = token.identifier, seen.insert(identifier).inserted else { continue }
            result.append(identifier)
        }
        return result
    }

    private static func scannedText(_ text: String) -> String {
        let source = text as NSString
        guard source.length > scanLimit else { return text }
        return source.substring(to: scanLimit)
    }
}

enum QueryToken: Equatable {
    case word(String)
    case quotedIdentifier(String)
    case literal
    case symbol(Character)

    var identifier: String? {
        switch self {
        case .word(let value), .quotedIdentifier(let value):
            return value
        case .literal, .symbol:
            return nil
        }
    }

    var keyword: String? {
        guard case .word(let value) = self else { return nil }
        return value.uppercased()
    }

    func isSymbol(_ character: Character) -> Bool {
        self == .symbol(character)
    }
}

enum QueryTokenScanner {
    static func tokens(
        in text: String,
        grammar: SQLLexicalGrammar,
        literalsAsIdentifiers: Bool = false
    ) -> [QueryToken] {
        let source = text as NSString
        let length = source.length
        let allowsDollarAndHash = grammar.contains(.dollarAndHashInIdentifiers)
        var tokens: [QueryToken] = []
        var index = 0

        while index < length {
            let unit = source.character(at: index)
            if SqlLexer.isWhitespace(unit) {
                index += 1
                continue
            }
            if let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) {
                if let token = token(for: span, in: source, literalsAsIdentifiers: literalsAsIdentifiers) {
                    tokens.append(token)
                }
                index = max(span.end, index + 1)
                continue
            }
            if isIdentifierUnit(unit, allowsDollarAndHash: allowsDollarAndHash) {
                let start = index
                while index < length,
                      isIdentifierUnit(source.character(at: index), allowsDollarAndHash: allowsDollarAndHash) {
                    index += 1
                }
                tokens.append(.word(source.substring(with: NSRange(location: start, length: index - start))))
                continue
            }
            if let scalar = UnicodeScalar(unit) {
                tokens.append(.symbol(Character(scalar)))
            }
            index += 1
        }
        return tokens
    }

    private static func token(
        for span: SQLNonCodeSpan.Span,
        in source: NSString,
        literalsAsIdentifiers: Bool
    ) -> QueryToken? {
        switch span.kind {
        case .lineComment, .blockComment, .executableComment:
            return nil
        case .parameter:
            return .literal
        case .quoted:
            let opener = source.character(at: span.start)
            let bodyStart = span.start + 1
            let bodyLength = max(0, span.contentEnd - bodyStart)
            let body = source.substring(with: NSRange(location: bodyStart, length: bodyLength))
            switch opener {
            case SqlLexer.doubleQuote:
                return .quotedIdentifier(body.replacingOccurrences(of: "\"\"", with: "\""))
            case SqlLexer.backtick:
                return .quotedIdentifier(body.replacingOccurrences(of: "``", with: "`"))
            case openBracket:
                return .quotedIdentifier(body.replacingOccurrences(of: "]]", with: "]"))
            case SqlLexer.singleQuote where literalsAsIdentifiers:
                return .quotedIdentifier(body.replacingOccurrences(of: "''", with: "'"))
            default:
                return .literal
            }
        }
    }

    private static func isIdentifierUnit(_ unit: UInt16, allowsDollarAndHash: Bool) -> Bool {
        if unit == underscore { return true }
        if allowsDollarAndHash, unit == dollar || unit == hash { return true }
        guard let scalar = UnicodeScalar(unit) else { return unit >= 0xD800 && unit <= 0xDFFF }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static let underscore = UInt16(UnicodeScalar("_").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let hash = UInt16(UnicodeScalar("#").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
}

private struct QueryReferenceParser {
    private let tokens: [QueryToken]
    private var listDepths: Set<Int> = []
    private var functionDepths: Set<Int> = []
    private var pendingIndexTarget = false
    private var found: [QueryTableReference] = []
    private var seen: Set<String> = []

    init(tokens: [QueryToken]) {
        self.tokens = tokens
    }

    mutating func references() -> [QueryTableReference] {
        let cteNames = commonTableExpressionNames()
        var depth = 0
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .symbol("("):
                depth += 1
                if opensFunctionArguments(at: index) {
                    functionDepths.insert(depth)
                }
            case .symbol(")"):
                listDepths.remove(depth)
                functionDepths.remove(depth)
                depth = max(0, depth - 1)
            case .symbol(";"):
                listDepths.removeAll()
                functionDepths.removeAll()
                pendingIndexTarget = false
                depth = 0
            case .symbol(","):
                if listDepths.contains(depth) {
                    record(readName(after: index, allowsFunction: false))
                }
            case .word:
                handleKeyword(at: index, depth: depth)
            case .quotedIdentifier, .literal, .symbol:
                break
            }
            index += 1
        }

        return found.filter { reference in
            !(reference.qualifiers.isEmpty && cteNames.contains(reference.name.lowercased()))
        }
    }

    private mutating func handleKeyword(at index: Int, depth: Int) {
        guard let keyword = tokens[index].keyword else { return }
        let previous = index > 0 ? tokens[index - 1].keyword : nil

        if Self.listEndingKeywords.contains(keyword) {
            listDepths.remove(depth)
        }

        switch keyword {
        case "FROM":
            guard !functionDepths.contains(depth), previous != "DISTINCT" else { return }
            listDepths.insert(depth)
            record(readName(after: index, allowsFunction: false))
        case "JOIN":
            record(readName(after: index, allowsFunction: false))
        case "UPDATE":
            guard previous.map({ !Self.nonTableUpdatePrefixes.contains($0) }) ?? true else { return }
            record(readName(after: index, allowsFunction: false))
        case "INTO", "REFERENCES":
            record(readName(after: index, allowsFunction: true))
        case "USING":
            record(readName(after: index, allowsFunction: false))
        case "TABLE":
            guard let previous, Self.tableStatementVerbs.contains(previous) else { return }
            record(readName(after: index, allowsFunction: true))
        case "INDEX":
            pendingIndexTarget = true
        case "ON":
            guard pendingIndexTarget else { return }
            pendingIndexTarget = false
            record(readName(after: index, allowsFunction: true))
        default:
            break
        }
    }

    private mutating func record(_ reference: QueryTableReference?) {
        guard let reference else { return }
        let key = reference.displayName.lowercased()
        guard seen.insert(key).inserted else { return }
        found.append(reference)
    }

    private func opensFunctionArguments(at openIndex: Int) -> Bool {
        guard openIndex > 0 else { return false }
        switch tokens[openIndex - 1] {
        case .word(let word):
            guard !Self.nonFunctionOpeners.contains(word.uppercased()) else { return false }
        case .quotedIdentifier:
            break
        case .literal, .symbol:
            return false
        }
        guard openIndex + 1 < tokens.count, let next = tokens[openIndex + 1].keyword else { return true }
        return next != "SELECT" && next != "WITH" && next != "VALUES"
    }

    private func readName(after index: Int, allowsFunction: Bool) -> QueryTableReference? {
        var cursor = index + 1
        while cursor < tokens.count, let keyword = tokens[cursor].keyword, Self.nameModifiers.contains(keyword) {
            cursor += 1
        }
        guard cursor < tokens.count, let first = nameSegment(at: cursor) else { return nil }

        var segments = [first]
        cursor += 1
        while cursor + 1 < tokens.count, tokens[cursor].isSymbol("."), let next = nameSegment(at: cursor + 1) {
            segments.append(next)
            cursor += 2
        }

        if !allowsFunction, cursor < tokens.count, tokens[cursor].isSymbol("(") {
            return nil
        }
        guard let name = segments.last else { return nil }
        return QueryTableReference(name: name, qualifiers: Array(segments.dropLast()))
    }

    private func nameSegment(at index: Int) -> String? {
        switch tokens[index] {
        case .quotedIdentifier(let value):
            return value.isEmpty ? nil : value
        case .word(let value):
            return Self.nonTableWords.contains(value.uppercased()) ? nil : value
        case .literal, .symbol:
            return nil
        }
    }

    private func commonTableExpressionNames() -> Set<String> {
        var names = Set<String>()
        for index in tokens.indices {
            guard let name = tokens[index].identifier,
                  tokens[index].keyword.map({ !Self.nonTableWords.contains($0) }) ?? true else { continue }
            var cursor = index + 1
            if cursor < tokens.count, tokens[cursor].isSymbol("(") {
                guard let close = matchingClose(from: cursor) else { continue }
                cursor = close + 1
            }
            guard cursor < tokens.count, tokens[cursor].keyword == "AS" else { continue }
            cursor += 1
            while cursor < tokens.count, let keyword = tokens[cursor].keyword,
                  keyword == "NOT" || keyword == "MATERIALIZED" {
                cursor += 1
            }
            guard cursor < tokens.count, tokens[cursor].isSymbol("(") else { continue }
            names.insert(name.lowercased())
        }
        return names
    }

    private func matchingClose(from openIndex: Int) -> Int? {
        var depth = 0
        for index in openIndex..<tokens.count {
            if tokens[index].isSymbol("(") {
                depth += 1
            } else if tokens[index].isSymbol(")") {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static let nameModifiers: Set<String> = [
        "ONLY", "LATERAL", "IF", "EXISTS", "NOT", "IGNORE", "LOW_PRIORITY", "QUICK", "DELAYED", "OVERWRITE"
    ]

    private static let tableStatementVerbs: Set<String> = [
        "TRUNCATE", "ALTER", "LOCK", "ANALYZE", "OPTIMIZE", "CHECK", "REPAIR", "DESCRIBE"
    ]

    private static let nonTableUpdatePrefixes: Set<String> = ["KEY", "FOR", "DO", "ON"]

    private static let nonFunctionOpeners: Set<String> = [
        "IN", "EXISTS", "FROM", "JOIN", "AS", "ANY", "ALL", "SOME", "ON", "USING", "VALUES", "LATERAL",
        "INTO", "TABLE", "WHERE", "AND", "OR", "NOT", "SELECT", "UNION", "INTERSECT", "EXCEPT", "WITH",
        "HAVING", "THEN", "ELSE", "WHEN", "RETURN", "SET", "BY"
    ]

    private static let listEndingKeywords: Set<String> = [
        "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "UNION", "INTERSECT", "EXCEPT",
        "MINUS", "SET", "RETURNING", "WINDOW", "QUALIFY", "FOR", "INTO", "VALUES", "SELECT", "WITH"
    ]

    private static let nonTableWords: Set<String> = [
        "SELECT", "WHERE", "SET", "VALUES", "ON", "USING", "AS", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
        "FULL", "CROSS", "NATURAL", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT",
        "EXCEPT", "RETURNING", "WINDOW", "DUAL", "DEFAULT", "NULL", "AND", "OR", "WITH", "FROM", "INTO",
        "TABLE", "UPDATE", "DELETE", "INSERT", "OUTFILE", "DUMPFILE", "NOWAIT", "SKIP", "OF", "CONCURRENTLY"
    ]
}
