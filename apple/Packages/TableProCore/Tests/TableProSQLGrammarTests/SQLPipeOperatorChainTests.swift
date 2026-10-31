import Foundation
import TableProSQLGrammar
import Testing

struct SQLPipeOperatorChainTests {
    private static let snowflake = SQLLexicalReadings.resolve(databaseTypeId: "Snowflake", declared: nil, session: nil)
        .execution

    private func links(_ sql: String, _ grammar: SQLLexicalGrammar = snowflake) -> [String] {
        SQLPipeOperatorChain.statements(in: sql, grammar: grammar).map(StatementBlank.trimming)
    }

    @Test("Snowflake is the only curated engine whose statements chain with a pipe operator")
    func onlySnowflakeChains() {
        let chaining = SQLLexicalProfile.curatedDatabaseTypeIds.filter { typeId in
            SQLLexicalProfile.curated(forDatabaseTypeId: typeId)?.readings.contains {
                $0.contains(.pipeOperatorChains)
            } == true
        }
        #expect(chaining == ["Snowflake"])
    }

    @Test("Every Snowflake reading a gate takes keeps the pipe operator")
    func everyReadingChains() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Snowflake", declared: nil, session: nil)
        #expect(readings.all.allSatisfy { $0.contains(.pipeOperatorChains) })
        #expect(readings.distinct(for: "SELECT 1 ->> DELETE FROM t").allSatisfy { $0.contains(.pipeOperatorChains) })
    }

    @Test("An engine nobody declared is not read as Snowflake, where ->> is JSON's operator")
    func unknownEnginesDoNotChain() {
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy { !$0.contains(.pipeOperatorChains) })
        let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil).execution
        #expect(links("SELECT doc ->> 'name' FROM t", postgreSQL).isEmpty)
    }

    @Test("Each statement the operator chains is returned", arguments: [
        ("SELECT 1 ->> DELETE FROM t", ["SELECT 1", "DELETE FROM t"]),
        ("SHOW TABLES ->> DROP TABLE t", ["SHOW TABLES", "DROP TABLE t"]),
        ("SHOW TABLES ->> SELECT \"name\" FROM $1 ->> SELECT COUNT(*) FROM $2", [
            "SHOW TABLES", "SELECT \"name\" FROM $1", "SELECT COUNT(*) FROM $2",
        ]),
        ("SELECT 1\n->>\nDELETE FROM t\n->> SELECT * FROM $1", ["SELECT 1", "DELETE FROM t", "SELECT * FROM $1"]),
        ("SELECT 1->>DELETE FROM t", ["SELECT 1", "DELETE FROM t"]),
    ])
    func chainedStatementsAreReturned(sql: String, expected: [String]) {
        #expect(links(sql) == expected)
    }

    @Test("A statement with no operator chains nothing", arguments: [
        "SELECT 1",
        "SELECT 1; DELETE FROM t",
        "SELECT '->> DELETE FROM t'",
        "SELECT $$->> DELETE FROM t$$",
        "SELECT 1 // ->> DELETE FROM t",
        "SELECT 1 /* ->> DELETE FROM t */",
        "SELECT a -> b FROM t",
    ])
    func plainStatementsAreUntouched(sql: String) {
        #expect(links(sql).isEmpty)
    }

    @Test("The operator is read where the engine reads it, so a literal cannot hide or fake one")
    func operatorIsReadFromCode() {
        #expect(links("SELECT 'a\\' ->> DELETE FROM t'").isEmpty)
        #expect(links("SELECT 'a\\'' ->> DELETE FROM t") == ["SELECT 'a\\''", "DELETE FROM t"])
        #expect(links("SELECT '->>' ->> DELETE FROM t") == ["SELECT '->>'", "DELETE FROM t"])
    }

    @Test("A link with no code in it runs nothing and is left out")
    func emptyLinksAreLeftOut() {
        #expect(links("SELECT 1 ->>") == ["SELECT 1"])
        #expect(links("->> DELETE FROM t") == ["DELETE FROM t"])
        #expect(links("SELECT 1 ->> -- later\n ->> DELETE FROM t") == ["SELECT 1", "DELETE FROM t"])
    }
}
