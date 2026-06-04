import Foundation

public enum QueryAutoLimitStyle: String, Sendable {
    case limit
    case fetchFirst
    case top
    case none
}

public struct QueryDialectDescriptor: Sendable {
    public let identifierQuote: String
    public let identifierClosingQuote: String
    public let keywords: Set<String>
    public let functions: Set<String>
    public let dataTypes: Set<String>
    public let tableOptions: [String]
    public let regexSyntax: RegexSyntax
    public let booleanLiteralStyle: BooleanLiteralStyle
    public let likeEscapeStyle: LikeEscapeStyle
    public let paginationStyle: PaginationStyle
    public let offsetFetchOrderBy: String
    public let requiresBackslashEscaping: Bool
    public let autoLimitStyle: QueryAutoLimitStyle

    public enum RegexSyntax: String, Sendable {
        case regexp
        case tilde
        case regexpMatches
        case match
        case regexpLike
        case unsupported
    }

    public enum BooleanLiteralStyle: String, Sendable {
        case truefalse
        case numeric
    }

    public enum LikeEscapeStyle: String, Sendable {
        case implicit
        case explicit
    }

    public enum PaginationStyle: String, Sendable {
        case limit
        case offsetFetch
    }

    public init(
        identifierQuote: String,
        identifierClosingQuote: String? = nil,
        keywords: Set<String>,
        functions: Set<String>,
        dataTypes: Set<String>,
        tableOptions: [String] = [],
        regexSyntax: RegexSyntax = .unsupported,
        booleanLiteralStyle: BooleanLiteralStyle = .numeric,
        likeEscapeStyle: LikeEscapeStyle = .explicit,
        paginationStyle: PaginationStyle = .limit,
        offsetFetchOrderBy: String = "ORDER BY (SELECT NULL)",
        requiresBackslashEscaping: Bool = false,
        autoLimitStyle: QueryAutoLimitStyle = .limit
    ) {
        self.identifierQuote = identifierQuote
        self.identifierClosingQuote = identifierClosingQuote ?? Self.defaultIdentifierClosingQuote(for: identifierQuote)
        self.keywords = keywords
        self.functions = functions
        self.dataTypes = dataTypes
        self.tableOptions = tableOptions
        self.regexSyntax = regexSyntax
        self.booleanLiteralStyle = booleanLiteralStyle
        self.likeEscapeStyle = likeEscapeStyle
        self.paginationStyle = paginationStyle
        self.offsetFetchOrderBy = offsetFetchOrderBy
        self.requiresBackslashEscaping = requiresBackslashEscaping
        self.autoLimitStyle = autoLimitStyle
    }
}

public extension QueryDialectDescriptor {
    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(
            of: identifierClosingQuote,
            with: "\(identifierClosingQuote)\(identifierClosingQuote)"
        )
        return "\(identifierQuote)\(escaped)\(identifierClosingQuote)"
    }

    var likeEscapeClause: String {
        likeEscapeStyle == .implicit ? "" : " ESCAPE '!'"
    }

    func sqlLiteral(
        for value: String,
        trimWhitespace: Bool = true,
        interpretSpecialLiterals: Bool = true
    ) -> String {
        let resolved = trimWhitespace ? value.trimmingCharacters(in: .whitespaces) : value

        if interpretSpecialLiterals {
            if resolved.caseInsensitiveCompare("NULL") == .orderedSame {
                return "NULL"
            }
            if resolved.caseInsensitiveCompare("TRUE") == .orderedSame {
                return booleanLiteralStyle == .truefalse ? "TRUE" : "1"
            }
            if resolved.caseInsensitiveCompare("FALSE") == .orderedSame {
                return booleanLiteralStyle == .truefalse ? "FALSE" : "0"
            }
        }

        if Self.isNumericLiteral(resolved) {
            return resolved
        }

        return "'\(escapeStringLiteralContent(resolved))'"
    }

    func escapeSQLQuote(_ value: String) -> String {
        guard value.contains("'") else { return value }
        return value.replacingOccurrences(of: "'", with: "''")
    }

    func escapeStringLiteralContent(_ value: String) -> String {
        var resolved = value.replacingOccurrences(of: "\0", with: "")
        if likeEscapeStyle == .implicit || requiresBackslashEscaping {
            resolved = resolved.replacingOccurrences(of: "\\", with: "\\\\")
        }
        return escapeSQLQuote(resolved)
    }

    func escapeLikeWildcards(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\0", with: "")
        switch likeEscapeStyle {
        case .explicit:
            result = result
                .replacingOccurrences(of: "!", with: "!!")
                .replacingOccurrences(of: "%", with: "!%")
                .replacingOccurrences(of: "_", with: "!_")
        case .implicit:
            if requiresBackslashEscaping {
                result = result.replacingOccurrences(of: "\\", with: "\\\\")
            }
            result = result
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
        }
        return result
    }

    private static func defaultIdentifierClosingQuote(for openingQuote: String) -> String {
        openingQuote == "[" ? "]" : openingQuote
    }

    private static func isNumericLiteral(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var scanner = value.makeIterator()
        var hasDigit = false
        var hasDot = false
        var hasE = false
        var first = true

        while let character = scanner.next() {
            if first {
                first = false
                if character == "-" || character == "+" { continue }
            }
            if character.isNumber {
                hasDigit = true
                continue
            }
            if character == "." && !hasDot && !hasE {
                hasDot = true
                continue
            }
            if (character == "e" || character == "E") && hasDigit && !hasE {
                hasE = true
                hasDigit = false
                if let next = scanner.next() {
                    if next == "+" || next == "-" || next.isNumber {
                        if next.isNumber { hasDigit = true }
                        continue
                    }
                }
                return false
            }
            return false
        }

        return hasDigit
    }
}
