//
//  SQLFormatterTypes.swift
//  TablePro
//

import Foundation

enum SQLFormatterCase: String, Codable, CaseIterable, Sendable {
    case upper
    case lower
    case preserve

    func applied(upper: String, original: String) -> String {
        switch self {
        case .upper: return upper
        case .lower: return upper.lowercased()
        case .preserve: return original
        }
    }
}

enum SQLFormatterIndentStyle: String, Codable, CaseIterable, Sendable {
    case spaces
    case tabs
}

enum SQLFormatterCommaPosition: String, Codable, CaseIterable, Sendable {
    case trailing
    case leading
}

enum SQLFormatterJoinCondition: String, Codable, CaseIterable, Sendable {
    case newLine
    case sameLine
}

enum SQLFormatterClauseItems: String, Codable, CaseIterable, Sendable {
    case sameLine
    case newLine
}

enum SQLFormatterLogicalOperatorNewline: String, Codable, CaseIterable, Sendable {
    case before
    case after
}

// The rule set the formatter runs with. Settings store it under their own keys (`SQLFormatterSettings`), a rules
// file under sql-formatter's (`SQLFormatterRulesFile`).
struct SQLFormatterOptions: Equatable, Sendable {
    static let indentWidthRange = 1...16
    static let lineWidthRange = 0...1_000

    var indentStyle: SQLFormatterIndentStyle = .spaces
    var indentWidth: Int = 2
    var keywordCase: SQLFormatterCase = .upper
    var functionCase: SQLFormatterCase = .preserve
    var commaPosition: SQLFormatterCommaPosition = .trailing
    // 0 puts each item of a SELECT list, SET list or WHERE chain on its own line.
    var lineWidth: Int = 0
    var joinCondition: SQLFormatterJoinCondition = .newLine
    var alignAliases: Bool = false
    var clauseItems: SQLFormatterClauseItems = .sameLine
    var logicalOperatorNewline: SQLFormatterLogicalOperatorNewline = .before
    // Applies only where the engine reads a type name in any case; ClickHouse's `String` is not `STRING`.
    var dataTypeCase: SQLFormatterCase = .preserve

    static let `default` = SQLFormatterOptions()

    var indentUnit: String {
        indentStyle == .tabs ? "\t" : String(repeating: " ", count: indentWidth)
    }
}

struct SQLFormatterResult {
    let formattedSQL: String
    let cursorOffset: Int?

    init(formattedSQL: String, cursorOffset: Int? = nil) {
        self.formattedSQL = formattedSQL
        self.cursorOffset = cursorOffset
    }
}

enum SQLFormatterError: LocalizedError {
    case emptyInput
    case inputTooLarge(maxBytes: Int)
    case dialectUnsupported(DatabaseType)
    case invalidCursorPosition(Int, max: Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return String(localized: "Cannot format empty SQL")
        case .inputTooLarge(let maxBytes):
            return String(
                format: String(localized: "The query is larger than %@, too large to format."),
                ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
            )
        case .dialectUnsupported(let type):
            return String(format: String(localized: "Formatting not supported for %@"), type.rawValue)
        case .invalidCursorPosition(let pos, let max):
            return String(format: String(localized: "Cursor position %d exceeds SQL length (%d)"), pos, max)
        }
    }
}

protocol SQLDialectProvider {
    var keywords: Set<String> { get }
    var functions: Set<String> { get }
    var dataTypes: Set<String> { get }
    var identifierQuote: String { get }
    // False where the engine rejects a built-in function spelled in another case (ClickHouse).
    var functionNamesAreCaseInsensitive: Bool { get }
    // False where a type name is matched by exact case (ClickHouse's `String`), or the dialect does not say.
    var typeNamesAreCaseInsensitive: Bool { get }
    // Symbols the engine reads as one operator, such as PostgreSQL's `@>` and `#>>`.
    var operators: Set<String> { get }

    func isKeyword(_ token: String) -> Bool
    func isFunction(_ token: String) -> Bool
    func isDataType(_ token: String) -> Bool
}

extension SQLDialectProvider {
    func isKeyword(_ token: String) -> Bool {
        keywords.contains(token.uppercased())
    }

    func isFunction(_ token: String) -> Bool {
        functions.contains(token.uppercased())
    }

    func isDataType(_ token: String) -> Bool {
        dataTypes.contains(token.uppercased())
    }
}
