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

    public enum PaginationStyle: String, Sendable {
        case limit       // MySQL, PostgreSQL, SQLite, etc: LIMIT n
        case offsetFetch // Oracle, MSSQL: OFFSET n ROWS FETCH NEXT m ROWS ONLY
    }

    public init(
        identifierQuote: String,
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
