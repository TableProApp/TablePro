import Foundation
import TableProSQLGrammar
import Testing

@Suite("SQL lexical readings")
struct SQLLexicalReadingsTests {
    @Test("Every SQL engine TablePro ships has a curated grammar")
    func curatedTableCoversShippedEngines() {
        let shipped = [
            "MySQL", "MariaDB", "TiDB", "Databend", "OceanBase", "PostgreSQL", "Redshift", "CockroachDB", "PGlite",
            "SQLite", "libSQL", "Turso", "Cloudflare D1", "DuckDB", "Oracle", "Dameng", "SQL Server", "ClickHouse",
            "Snowflake", "BigQuery", "Spanner", "Trino", "Teradata", "Cassandra", "ScyllaDB", "DynamoDB",
            "SurrealDB", "Redis", "MongoDB", "etcd", "Elasticsearch", "Typesense", "Weaviate", "Kafka",
        ]
        let missing = shipped.filter { SQLLexicalProfile.curated(forDatabaseTypeId: $0) == nil }
        #expect(missing.isEmpty)
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

    @Test("PartiQL's doubled quote still closes nothing under DynamoDB's execution grammar")
    func dynamoDBPartiQLDoubledQuoteStillLexes() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "DynamoDB", declared: nil, session: nil)
        let text = #"SELECT * FROM "a""b"; DELETE FROM "t""#

        let executed = SQLStatementScanner.executableStatements(in: text, grammar: readings.execution).map(\.sql)

        #expect(executed == [#"SELECT * FROM "a""b""#, #"DELETE FROM "t""#])
    }

    @Test("Every combination of the undetermined facts is a reading")
    func undeterminedFactsExpand() {
        let profile = SQLLexicalProfile(grammar: .ansi, undetermined: [.hashLineComments, .nestedBlockComments])
        #expect(Set(profile.readings) == [
            [], [.hashLineComments], [.nestedBlockComments], [.hashLineComments, .nestedBlockComments],
        ])
        #expect(profile.readings.first == .ansi)
    }
}
