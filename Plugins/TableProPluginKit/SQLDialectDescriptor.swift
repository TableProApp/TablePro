import Foundation

public struct CompletionEntry: Sendable {
    public let label: String
    public let insertText: String
    public init(label: String, insertText: String) {
        self.label = label
        self.insertText = insertText
    }
}

public enum AutoLimitStyle: String, Sendable {
    case limit       // LIMIT n
    case fetchFirst  // FETCH FIRST n ROWS ONLY (Oracle)
    case top         // SELECT TOP n ... (MSSQL)
    case none        // Don't auto-limit (non-SQL)
}

public struct SQLDialectDescriptor: Sendable {
    public let identifierQuote: String
    public let identifierClosingQuote: String
    public let keywords: Set<String>
    public let functions: Set<String>
    public let dataTypes: Set<String>
    public let tableOptions: [String]

    // Filter dialect
    public let regexSyntax: RegexSyntax
    public let booleanLiteralStyle: BooleanLiteralStyle
    public let likeEscapeStyle: LikeEscapeStyle
    public let paginationStyle: PaginationStyle
    public let offsetFetchOrderBy: String
    public let requiresBackslashEscaping: Bool

    // Query limit style
    public let autoLimitStyle: AutoLimitStyle

    @frozen
    public enum RegexSyntax: String, Sendable {
        case regexp        // MySQL: column REGEXP 'pattern'
        case tilde         // PostgreSQL: column ~ 'pattern'
        case regexpMatches // DuckDB: regexp_matches(column, 'pattern')
        case match         // ClickHouse: match(column, 'pattern')
        case regexpLike    // Oracle: REGEXP_LIKE(column, 'pattern')
        case unsupported   // SQLite, MSSQL, MongoDB, Redis
    }

    public enum BooleanLiteralStyle: String, Sendable {
        case truefalse // PostgreSQL, DuckDB: TRUE/FALSE
        case numeric   // MySQL, SQLite, etc: 1/0
    }

    public enum LikeEscapeStyle: String, Sendable {
        case implicit // MySQL: backslash is default escape, no ESCAPE clause needed
        case explicit // PostgreSQL, SQLite, etc: need ESCAPE '\' clause
    }

    @frozen
    public enum PaginationStyle: String, Sendable {
        case limit       // MySQL, PostgreSQL, SQLite, etc: LIMIT n
        case offsetFetch // Oracle, MSSQL: OFFSET n ROWS FETCH NEXT m ROWS ONLY
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
        autoLimitStyle: AutoLimitStyle = .limit
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

    public func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(
            of: identifierClosingQuote,
            with: "\(identifierClosingQuote)\(identifierClosingQuote)"
        )
        return "\(identifierQuote)\(escaped)\(identifierClosingQuote)"
    }

    public var likeEscapeClause: String {
        likeEscapeStyle == .implicit ? "" : " ESCAPE '!'"
    }

    public func sqlLiteral(
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

        if PluginNumericLiteral.isValid(resolved) {
            return resolved
        }

        return "'\(escapeStringLiteralContent(resolved))'"
    }

    public func escapeSQLQuote(_ value: String) -> String {
        guard value.contains("'") else { return value }
        return value.replacingOccurrences(of: "'", with: "''")
    }

    public func escapeStringLiteralContent(_ value: String) -> String {
        if likeEscapeStyle == .implicit || requiresBackslashEscaping {
            guard value.contains("\\") || value.contains("'") else { return value }
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "''")
        }
        return escapeSQLQuote(value)
    }

    public func escapeLikeWildcards(_ value: String) -> String {
        if likeEscapeStyle == .implicit {
            guard value.contains("\\") || value.contains("%") || value.contains("_") else { return value }
            return value
                .replacingOccurrences(of: "\\", with: "\\\\\\\\")
                .replacingOccurrences(of: "%", with: "\\\\%")
                .replacingOccurrences(of: "_", with: "\\\\_")
        }
        guard value.contains("!") || value.contains("%") || value.contains("_") else { return value }
        return value
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
    }

    private static func defaultIdentifierClosingQuote(for openingQuote: String) -> String {
        openingQuote == "[" ? "]" : openingQuote
    }
}
