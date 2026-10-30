import Foundation

// Each engine's plugin dialect, the macOS curated metadata and the iOS editor read these lists, so they cannot drift.
public struct SQLEngineVocabulary: Sendable, Hashable {
    public struct Operator: Sendable, Hashable {
        public let symbol: String
        public let summary: String
        // SQLOperatorDescriptor.Category and .Placement raw values: a PluginKit type here would give a plugin a
        // second copy of PluginKit.
        public let category: String
        public let placement: String
        public let appliesToTypes: [String]

        public init(
            symbol: String,
            summary: String,
            category: String,
            placement: String = "infix",
            appliesToTypes: [String] = []
        ) {
            self.symbol = symbol
            self.summary = summary
            self.category = category
            self.placement = placement
            self.appliesToTypes = appliesToTypes
        }
    }

    public let functions: Set<String>
    // Written with no parentheses: `SYSDATE()` is an error on Oracle, `CURRENT_DATE()` on PostgreSQL.
    public let bareFunctions: Set<String>
    public let functionNamesAreCaseInsensitive: Bool
    public let dataTypes: Set<String>
    public let tableOptions: [String]
    public let operators: [Operator]

    public init(
        functions: Set<String>,
        bareFunctions: Set<String> = [],
        functionNamesAreCaseInsensitive: Bool = true,
        dataTypes: Set<String>,
        tableOptions: [String] = [],
        operators: [Operator] = []
    ) {
        self.functions = functions
        self.bareFunctions = bareFunctions
        self.functionNamesAreCaseInsensitive = functionNamesAreCaseInsensitive
        self.dataTypes = dataTypes
        self.tableOptions = tableOptions
        self.operators = operators
    }

    public static func curated(forDatabaseTypeId typeId: String) -> SQLEngineVocabulary? {
        vocabularies[typeId]
    }

    public static var curatedDatabaseTypeIds: Set<String> {
        Set(vocabularies.keys)
    }

    private static let vocabularies: [String: SQLEngineVocabulary] = [
        "MySQL": mySQL,
        "MariaDB": mySQL,
        "TiDB": mySQL,
        "Databend": mySQL,
        "OceanBase": mySQL,
        "PostgreSQL": postgreSQL,
        "CockroachDB": postgreSQL,
        "PGlite": postgreSQL,
        "KingbaseES": postgreSQL,
        "Redshift": redshift,
        "SQLite": sqlite,
        "SQL Server": sqlServer,
        "Oracle": oracle,
        "DuckDB": duckDB,
    ]
}
