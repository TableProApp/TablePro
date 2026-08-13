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

public struct SQLOperatorDescriptor: Sendable, Hashable {
    public enum Placement: String, Sendable {
        case infix
        case prefix
        case postfix
    }

    public enum Category: String, Sendable {
        case cast
        case comparison
        case predicate
        case logical
        case math
        case bitwise
        case string
        case pattern
        case json
        case array
        case range
        case fullText
        case network
        case geometric
        case vector
    }

    public let symbol: String
    public let summary: String
    public let category: Category
    public let placement: Placement
    public let appliesToTypes: [String]

    public init(
        symbol: String,
        summary: String,
        category: Category,
        placement: Placement = .infix,
        appliesToTypes: [String] = []
    ) {
        self.symbol = symbol
        self.summary = summary
        self.category = category
        self.placement = placement
        self.appliesToTypes = appliesToTypes
    }
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

    // Case-insensitive matching
    public let caseSensitivityStyle: CaseSensitivityStyle
    public let caseFoldFunction: String

    // Authoring
    public let operators: [SQLOperatorDescriptor]

    public enum CaseSensitivityStyle: String, Sendable {
        case ilikeOperator    // PostgreSQL, CockroachDB, PGlite, DuckDB, Snowflake
        case caseFoldFunction // Oracle, BigQuery, ClickHouse, Redshift
        case regexFlag        // Trino
        case driverManaged    // MongoDB, Elasticsearch, DynamoDB, etcd
        case collationDefined // MySQL, MSSQL, SQLite and their compatible engines
        case unsupported      // Cassandra, Redis, and any plugin built before this field
    }

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

    @_disfavoredOverload
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
        self.init(
            identifierQuote: identifierQuote,
            keywords: keywords,
            functions: functions,
            dataTypes: dataTypes,
            tableOptions: tableOptions,
            regexSyntax: regexSyntax,
            booleanLiteralStyle: booleanLiteralStyle,
            likeEscapeStyle: likeEscapeStyle,
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: offsetFetchOrderBy,
            requiresBackslashEscaping: requiresBackslashEscaping,
            autoLimitStyle: autoLimitStyle,
            caseSensitivityStyle: .unsupported,
            caseFoldFunction: Self.defaultCaseFoldFunction
        )
    }

    @_disfavoredOverload
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
        autoLimitStyle: AutoLimitStyle = .limit,
        caseSensitivityStyle: CaseSensitivityStyle = .unsupported,
        caseFoldFunction: String = SQLDialectDescriptor.defaultCaseFoldFunction
    ) {
        self.init(
            identifierQuote: identifierQuote,
            keywords: keywords,
            functions: functions,
            dataTypes: dataTypes,
            tableOptions: tableOptions,
            regexSyntax: regexSyntax,
            booleanLiteralStyle: booleanLiteralStyle,
            likeEscapeStyle: likeEscapeStyle,
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: offsetFetchOrderBy,
            requiresBackslashEscaping: requiresBackslashEscaping,
            autoLimitStyle: autoLimitStyle,
            caseSensitivityStyle: caseSensitivityStyle,
            caseFoldFunction: caseFoldFunction,
            operators: []
        )
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
        autoLimitStyle: AutoLimitStyle = .limit,
        caseSensitivityStyle: CaseSensitivityStyle = .unsupported,
        caseFoldFunction: String = SQLDialectDescriptor.defaultCaseFoldFunction,
        operators: [SQLOperatorDescriptor] = []
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
        self.caseSensitivityStyle = caseSensitivityStyle
        self.caseFoldFunction = caseFoldFunction
        self.operators = operators
    }

    public static let defaultCaseFoldFunction = "LOWER"

    public func withCaseSensitivityStyle(
        _ style: CaseSensitivityStyle,
        caseFoldFunction: String = SQLDialectDescriptor.defaultCaseFoldFunction
    ) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: identifierQuote,
            keywords: keywords,
            functions: functions,
            dataTypes: dataTypes,
            tableOptions: tableOptions,
            regexSyntax: regexSyntax,
            booleanLiteralStyle: booleanLiteralStyle,
            likeEscapeStyle: likeEscapeStyle,
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: offsetFetchOrderBy,
            requiresBackslashEscaping: requiresBackslashEscaping,
            autoLimitStyle: autoLimitStyle,
            caseSensitivityStyle: style,
            caseFoldFunction: caseFoldFunction,
            operators: operators
        )
    }
}
