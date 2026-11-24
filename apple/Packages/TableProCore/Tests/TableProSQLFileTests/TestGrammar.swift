import TableProSQLGrammar

// The grammar each engine is split with, resolved as both apps resolve it for an engine TablePro curates.
enum TestGrammar {
    static func of(_ databaseTypeId: String, session: SQLSessionLexicalFacts? = nil) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: databaseTypeId, declared: nil, session: session).execution
    }

    static let postgres = of("PostgreSQL")
    static let mysql = of("MySQL")
    static let sqlite = of("SQLite")
    static let duckdb = of("DuckDB")
    static let sqlServer = of("SQL Server")
    static let cockroachDB = of("CockroachDB")
    static let cassandra = of("Cassandra")
}
