import Foundation
import TableProSQLGrammar
import Testing

@Suite("SQL lexical readings")
struct SQLLexicalReadingsTests {
    @Test("Every SQL engine TablePro ships has a curated grammar")
    func curatedTableCoversShippedEngines() {
        let shipped = [
            "MySQL", "MariaDB", "TiDB", "Databend", "OceanBase", "StarRocks", "PostgreSQL", "Redshift", "CockroachDB", "PGlite", "KingbaseES",
            "SQLite", "libSQL", "Turso", "Cloudflare D1", "DuckDB", "Oracle", "Dameng", "SQL Server", "ClickHouse",
            "Snowflake", "BigQuery", "Spanner", "Trino", "Presto", "Teradata", "SAP HANA", "Cassandra", "ScyllaDB", "DynamoDB",
            "SurrealDB", "Redis", "MongoDB", "etcd", "Elasticsearch", "Typesense", "Weaviate", "Kafka",
            "Firestore", "Firebase Realtime Database", "Bigtable", "InfluxDB",
        ]
        let missing = shipped.filter { SQLLexicalProfile.curated(forDatabaseTypeId: $0) == nil }
        #expect(missing.isEmpty)
    }

    @Test("Only T-SQL names continue with # and @")
    func hashAndAtContinueOnlyTSQLNames() {
        #expect(SQLLexicalProfile.curated(forDatabaseTypeId: "SQL Server")?.grammar.contains(.hashAndAtInIdentifiers) == true)
        for typeId in ["MySQL", "PostgreSQL", "SQLite", "Oracle", "ClickHouse", "DuckDB"] {
            #expect(SQLLexicalProfile.curated(forDatabaseTypeId: typeId)?.grammar.contains(.hashAndAtInIdentifiers) == false)
        }
    }

    @Test("A curated engine ignores what a plugin declares, because a registry plugin may be older than the app")
    func curatedGrammarWinsOverDeclaration() {
        let readings = SQLLexicalReadings.resolve(
            databaseTypeId: "PostgreSQL",
            declared: [.backslashEscapesInSingleQuotes, .hashLineComments],
            session: nil
        )
        #expect(!readings.execution.contains(.hashLineComments))
        #expect(readings.execution.contains(.nestedBlockComments))
    }

    @Test("An engine TablePro does not know is split as its plugin declares and read as nothing else")
    func declaredGrammarServesUnknownEngines() {
        let declared: SQLLexicalGrammar = [.bracketQuotedIdentifiers, .nestedBlockComments]
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Nonesuch", declared: declared, session: nil)
        #expect(readings.execution == declared)
        #expect(readings.all == [declared])
    }

    @Test("An engine nobody declared is split as standard SQL and read under every grammar TablePro knows")
    func undeclaredUnknownEngineReadsEverything() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Nonesuch", declared: nil, session: nil)
        #expect(readings.execution == .ansi)
        #expect(readings.all.count > 10)
        #expect(readings.all.allSatisfy { !$0.contains(.plsqlBlocks) })
    }

    @Test("A session fact chooses the execution grammar without narrowing what a gate reads")
    func sessionFactsChooseExecutionOnly() {
        let noBackslash = SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes],
            enabled: []
        )
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: noBackslash)
        #expect(!readings.execution.contains(.backslashEscapesInSingleQuotes))
        #expect(readings.all.contains { $0.contains(.backslashEscapesInSingleQuotes) })
        #expect(readings.all.contains { !$0.contains(.backslashEscapesInSingleQuotes) })
    }

    @Test("A fact the session reports outside the curated doubt still reaches the gate")
    func sessionFactOutsideTheProfileWidensTheReadings() {
        let escapes = SQLSessionLexicalFacts(determined: .hashLineComments, enabled: .hashLineComments)
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Oracle", declared: nil, session: escapes)
        #expect(readings.execution.contains(.hashLineComments))
        #expect(readings.all.count == 2)
    }

    @Test("A fact no character in the text can trigger collapses the readings to one")
    func irrelevantFactsCollapse() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil)
        #expect(readings.all.count > 1)
        #expect(readings.distinct(for: "SELECT a FROM t WHERE b = 'c'").count == 1)
        #expect(readings.distinct(for: "SELECT 'a\\'").count == 4)
    }

    @Test("Spanner's grammar is either dialect until the database says which")
    func spannerReadsBothDialects() {
        let profile = SQLLexicalProfile.curated(forDatabaseTypeId: "Spanner")
        let readings = profile?.readings ?? []
        #expect(readings.contains { $0.contains(.tripleQuotedStrings) })
        #expect(readings.contains { $0.contains(.taggedDollarQuotes) })
    }

    @Test("A DynamoDB request whose JSON string escapes a quote is one statement to the driver")
    func dynamoDBRequestKeepsEscapedQuotesInsideTheString() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "DynamoDB", declared: nil, session: nil)
        let text = #"PutItem {"TableName": "t", "Item": {"a": {"S": "x\";y"}}}; SELECT * FROM "t""#

        let executed = SQLStatementScanner.executableStatements(in: text, grammar: readings.execution).map(\.sql)

        #expect(executed == [#"PutItem {"TableName": "t", "Item": {"a": {"S": "x\";y"}}}"#, #"SELECT * FROM "t""#])
    }

    @Test("DynamoDB keeps plain ANSI as a reading, so a gate still counts what PartiQL could split")
    func dynamoDBGateReadsTheANSIReading() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "DynamoDB", declared: nil, session: nil)
        let text = #"PutItem {"TableName": "t", "Item": {"a": {"S": "x\";y\";z"}}}; SELECT * FROM "t""#

        let counts = readings.distinct(for: text).map {
            SQLStatementScanner.executableStatements(in: text, grammar: $0).count
        }

        #expect(readings.all.contains(.ansi))
        #expect(SQLStatementScanner.executableStatements(in: text, grammar: readings.execution).count == 2)
        #expect(counts.max() == 3)
    }

    @Test("InfluxDB splits InfluxQL's backslash-escaped quote and Flux's `//` comment as one statement each")
    func influxDBKeepsInfluxQLEscapesAndFluxComments() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "InfluxDB", declared: nil, session: nil)
        let influxQL = #"SELECT * FROM cpu WHERE note = 'it\'s; x'; SHOW MEASUREMENTS"#
        let flux = "// don't; split\nfrom(bucket: \"m\") |> range(start: -1h)"

        #expect(readings.all.contains(.ansi))
        #expect(SQLStatementScanner.executableStatements(in: influxQL, grammar: readings.execution).count == 2)
        #expect(SQLStatementScanner.executableStatements(in: flux, grammar: readings.execution).count == 1)
    }

    @Test("SQL Server's `1E--` is read as a comment and as a signed exponent, and any other `--` once")
    func sqlServerReadsASignedEmptyExponentBothWays() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        func statements(_ text: String) -> [Int] {
            readings.distinct(for: text).map { SQLStatementScanner.executableStatements(in: text, grammar: $0).count }
        }

        #expect(!readings.execution.contains(.exponentSignsNeedNoDigits))
        #expect(statements("SELECT 1E--1; DROP TABLE t") == [1, 2])
        #expect(statements("SELECT 1E--'\n; DROP TABLE t --'") == [2, 1])
        #expect(statements("SELECT 1 --1; DROP TABLE t") == [1])
    }

    @Test("PartiQL's doubled quote still closes nothing under DynamoDB's execution grammar")
    func dynamoDBPartiQLDoubledQuoteStillLexes() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "DynamoDB", declared: nil, session: nil)
        let text = #"SELECT * FROM "a""b"; DELETE FROM "t""#

        let executed = SQLStatementScanner.executableStatements(in: text, grammar: readings.execution).map(\.sql)

        #expect(executed == [#"SELECT * FROM "a""b""#, #"DELETE FROM "t""#])
    }

    @Test("ClickHouse reads // as a line comment, so a quote behind it opens no string")
    func clickHouseReadsDoubleSlashComments() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "ClickHouse", declared: nil, session: nil)
        let hidden = "WITH y AS (SELECT 1 AS id) //'\nINSERT INTO orders SELECT * FROM y --'"

        #expect(readings.all.allSatisfy { SQLCodeProjection.code(of: hidden, grammar: $0).contains("INSERT INTO orders") })
    }

    @Test(
        "A statement after a quote inside a SurrealQL ⟨...⟩ identifier is counted, however a backslash is read",
        arguments: [
            "SELECT ⟨'⟩ FROM person; REMOVE TABLE person; --'",
            "SELECT ⟨\\⟩'⟩ FROM person; REMOVE TABLE person; --'",
            "SELECT ⟨\\⟩ FROM person; REMOVE TABLE person; --⟩",
            "SELECT `'` FROM person; REMOVE TABLE person; --'",
        ]
    )
    func surrealQLQuotedIdentifiersHideNoStatement(text: String) {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "SurrealDB", declared: nil, session: nil)

        let counts = readings.distinct(for: text).map {
            SQLStatementScanner.executableStatements(in: text, grammar: $0).count
        }

        #expect(counts.max() == 2)
    }

    @Test("A quote or a semicolon inside a SurrealQL ⟨...⟩ identifier stays in its one statement")
    func surrealQLAngleQuotedIdentifierIsOneToken() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "SurrealDB", declared: nil, session: nil)
        let text = "SELECT ⟨it's;⟩ FROM person:⟨8424486b-85b3⟩"

        #expect(readings.distinct(for: text).count == 1)
        #expect(SQLStatementScanner.executableStatements(in: text, grammar: readings.execution).map(\.sql) == [text])
    }

    @Test("A form feed ends a Databend line comment, so the statement after it is counted")
    func databendFormFeedEndsALineComment() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Databend", declared: nil, session: nil)
        let text = "-- note\u{0C}DROP TABLE customers /*\nSELECT 1 -- */"

        let codes = readings.distinct(for: text).map { SQLCodeProjection.code(of: text, grammar: $0) }

        #expect(codes.contains { $0.contains("DROP TABLE customers") })
    }

    @Test("Every combination of the undetermined facts is a reading")
    func undeterminedFactsExpand() {
        let profile = SQLLexicalProfile(grammar: .ansi, undetermined: [.hashLineComments, .nestedBlockComments])
        #expect(Set(profile.readings) == [
            [], [.hashLineComments], [.nestedBlockComments], [.hashLineComments, .nestedBlockComments],
        ])
        #expect(profile.readings.first == .ansi)
    }
    @Test("KingbaseES retains both compatibility-mode readings before a session is known")
    func kingbaseCompatibilityReadings() throws {
        let profile = try #require(SQLLexicalProfile.curated(forDatabaseTypeId: "KingbaseES"))
        #expect(profile.grammar.contains(.taggedDollarQuotes))
        #expect(profile.readings.contains { $0.contains(.alternativeQuoting) && $0.contains(.plsqlBlocks) })
        let oracle = SQLSessionLexicalFacts(
            determined: [.alternativeQuoting, .plsqlBlocks], enabled: [.alternativeQuoting, .plsqlBlocks]
        )
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "KingbaseES", declared: nil, session: oracle)
        #expect(readings.execution.contains(.alternativeQuoting))
        #expect(readings.execution.contains(.plsqlBlocks))
        #expect(readings.all.contains { !$0.contains(.alternativeQuoting) })
    }

    // Measured on KingbaseES V9R1C10 in Oracle mode: each of these creates its function, beside PL/SQL bodies.
    @Test("Oracle-mode KingbaseES ends a quoted routine body at its semicolon and keeps a PL/SQL body whole")
    func kingbaseOracleModeRoutineBodies() {
        let oracle = SQLSessionLexicalFacts(
            determined: [.alternativeQuoting, .plsqlBlocks, .slashLineTerminators, .dollarAndHashInIdentifiers],
            enabled: [.alternativeQuoting, .plsqlBlocks, .slashLineTerminators, .dollarAndHashInIdentifiers]
        )
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: "KingbaseES", declared: nil, session: oracle).execution
        func sent(_ sql: String) -> [String] {
            SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
        }
        #expect(sent("CREATE FUNCTION f() RETURNS integer LANGUAGE SQL AS 'SELECT 42'; SELECT 2;").count == 2)
        #expect(sent("CREATE FUNCTION f() RETURNS integer AS $$ SELECT 1; $$ LANGUAGE sql; SELECT 2;").count == 2)
        #expect(sent("CREATE FUNCTION f() RETURNS integer AS $b$ BEGIN RETURN 1; END; $b$ LANGUAGE plpgsql; SELECT 2;").count == 2)
        #expect(sent("CREATE FUNCTION f RETURN NUMBER AS BEGIN RETURN 1; END;\n/\nSELECT 2;").count == 2)
        #expect(sent("CREATE FUNCTION f RETURN NUMBER AS \"v\" NUMBER := 1; BEGIN RETURN \"v\"; END;\n/\nSELECT 2;").count == 2)
    }
}
