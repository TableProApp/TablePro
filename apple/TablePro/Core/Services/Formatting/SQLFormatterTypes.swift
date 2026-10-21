//
//  SQLFormatterTypes.swift
//  TablePro
//

import Foundation

// A word the formatter writes itself, the `BY` of `ORDER BY`, has no spelling to preserve: lower case.
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

    func synthesized(_ upper: String) -> String {
        switch self {
        case .upper: return upper
        case .lower, .preserve: return upper.lowercased()
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

// The rule set the formatter runs with, and the JSON a rules file holds.
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

    static let `default` = SQLFormatterOptions()

    var indentUnit: String {
        indentStyle == .tabs ? "\t" : String(repeating: " ", count: indentWidth)
    }
}

extension SQLFormatterOptions: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case indentStyle
        case indentWidth
        case keywordCase
        case functionCase
        case commaPosition
        case lineWidth
        case joinCondition
        case alignAliases
    }

    // Strict, for files: a value this build can't read throws, a key it doesn't know is ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        indentStyle = try container.decodeIfPresent(SQLFormatterIndentStyle.self, forKey: .indentStyle)
            ?? fallback.indentStyle
        indentWidth = try Self.decodeInt(container, .indentWidth, in: Self.indentWidthRange) ?? fallback.indentWidth
        keywordCase = try container.decodeIfPresent(SQLFormatterCase.self, forKey: .keywordCase) ?? fallback.keywordCase
        functionCase = try container.decodeIfPresent(SQLFormatterCase.self, forKey: .functionCase)
            ?? fallback.functionCase
        commaPosition = try container.decodeIfPresent(SQLFormatterCommaPosition.self, forKey: .commaPosition)
            ?? fallback.commaPosition
        lineWidth = try Self.decodeInt(container, .lineWidth, in: Self.lineWidthRange) ?? fallback.lineWidth
        joinCondition = try container.decodeIfPresent(SQLFormatterJoinCondition.self, forKey: .joinCondition)
            ?? fallback.joinCondition
        alignAliases = try container.decodeIfPresent(Bool.self, forKey: .alignAliases) ?? fallback.alignAliases
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(indentStyle, forKey: .indentStyle)
        try container.encode(indentWidth, forKey: .indentWidth)
        try container.encode(keywordCase, forKey: .keywordCase)
        try container.encode(functionCase, forKey: .functionCase)
        try container.encode(commaPosition, forKey: .commaPosition)
        try container.encode(lineWidth, forKey: .lineWidth)
        try container.encode(joinCondition, forKey: .joinCondition)
        try container.encode(alignAliases, forKey: .alignAliases)
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        in range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard range.contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return value
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
    case dialectUnsupported(DatabaseType)
    case invalidCursorPosition(Int, max: Int)
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return String(localized: "Cannot format empty SQL")
        case .dialectUnsupported(let type):
            return String(format: String(localized: "Formatting not supported for %@"), type.rawValue)
        case .invalidCursorPosition(let pos, let max):
            return String(format: String(localized: "Cursor position %d exceeds SQL length (%d)"), pos, max)
        case .internalError(let message):
            return String(format: String(localized: "Formatter error: %@"), message)
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
