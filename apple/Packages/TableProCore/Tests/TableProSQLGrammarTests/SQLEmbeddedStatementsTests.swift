import Foundation
import TableProSQLGrammar
import Testing

struct SQLEmbeddedStatementsTests {
    private static func grammar(_ typeId: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
    }

    private static let surrealQL = grammar("SurrealDB")
    private static let cockroachDB = grammar("CockroachDB")

    private func embedded(_ sql: String, _ grammar: SQLLexicalGrammar) -> [String] {
        SQLUnterminatedStatements.runnable(in: sql, grammar: grammar).dropFirst().map(StatementBlank.trimming)
    }

    private func engines(reading fact: SQLLexicalGrammar) -> Set<String> {
        SQLLexicalProfile.curatedDatabaseTypeIds.filter { typeId in
            SQLLexicalProfile.curated(forDatabaseTypeId: typeId)?.readings.contains { $0.contains(fact) } == true
        }
    }

    @Test("Only SurrealDB takes a statement as a value, and only CockroachDB one in brackets as a table")
    func onlyTheTwoEnginesEmbedStatements() {
        #expect(engines(reading: .statementsAsValues) == ["SurrealDB"])
        #expect(engines(reading: .bracketedStatementSources) == ["CockroachDB"])
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy {
            $0.isDisjoint(with: [.statementsAsValues, .bracketedStatementSources])
        })
    }

    @Test("Every reading a gate takes of a text that embeds a statement still finds it", arguments: [
        ("SurrealDB", "SELECT * FROM orders -- all\r WHERE (DELETE orders)"),
        ("CockroachDB", "SELECT $$a$$ /* /* */ */ FROM [DELETE FROM orders RETURNING id] -- x\r"),
    ])
    func everyReadingFindsIt(typeId: String, sql: String) {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil)
        let distinct = readings.distinct(for: sql)
        #expect(distinct.count > 1)
        #expect(distinct.allSatisfy { !$0.isDisjoint(with: [.statementsAsValues, .bracketedStatementSources]) })
    }

    // MARK: - SurrealQL

    @Test("A SurrealQL statement that opens a group runs to the end of the group", arguments: [
        ("SELECT * FROM (DELETE orders RETURN BEFORE)", "DELETE orders RETURN BEFORE"),
        ("SELECT * FROM orders WHERE (DELETE orders)", "DELETE orders"),
        ("SELECT * FROM orders WHERE (DELETE orders WHERE paid) AND total > 1", "DELETE orders WHERE paid"),
        ("SELECT * FROM (REMOVE TABLE orders)", "REMOVE TABLE orders"),
        ("SELECT * FROM (DEFINE USER x ON DB PASSWORD 'p' ROLES OWNER)", "DEFINE USER x ON DB PASSWORD 'p' ROLES OWNER"),
        ("SELECT * FROM { DELETE orders } WHERE true", "DELETE orders"),
        ("SELECT * FROM [DELETE orders] WHERE true", "DELETE orders"),
        ("select * from (/* all */ delete orders)", "delete orders"),
        ("UPDATE a SET gone = (DELETE orders) WHERE id = 1", "DELETE orders"),
    ])
    func groupedSurrealQLStatement(sql: String, statement: String) {
        #expect(embedded(sql, Self.surrealQL) == [statement])
    }

    @Test("A bare SurrealQL statement is its first word, so no clause around it is read as its own", arguments: [
        "SELECT * FROM DELETE orders",
        "SELECT DELETE orders FROM customers WHERE true",
        "SELECT * FROM [1, DELETE orders]",
        "SELECT * FROM 1..DELETE orders",
        "SELECT * FROM (IF DELETE orders THEN SELECT * FROM customers WHERE true END)",
        "SELECT DELETE orders, DELETE customers FROM 1",
    ])
    func bareSurrealQLStatement(sql: String) {
        #expect(embedded(sql, Self.surrealQL) == ["DELETE"])
    }

    @Test("A SurrealQL statement nested in another comes on its own")
    func nestedSurrealQLStatements() {
        #expect(
            embedded("SELECT * FROM (DELETE orders WHERE id IN (CREATE log RETURN id) RETURN BEFORE)", Self.surrealQL)
                == ["DELETE orders WHERE id IN () RETURN BEFORE", "CREATE log RETURN id"]
        )
    }

    @Test("A SurrealQL name, literal or comment that spells a statement word is not a statement", arguments: [
        "SELECT * FROM orders",
        "SELECT * FROM orders WHERE (SELECT * FROM customers)",
        "SELECT created, 'DELETE', \"(DELETE orders)\" FROM orders",
        "SELECT array::insert(tags, 'x'), row.update, $delete, `create` FROM orders",
        "SELECT updated, deleted_at, create_time FROM orders -- (DELETE orders)",
        "SELECT * FROM orders # (DELETE orders)",
        "DELETE orders",
        "(DELETE orders)",
        "DEFINE TABLE post PERMISSIONS FOR select, create FULL FOR update, delete NONE",
        "DEFINE FIELD author ON post TYPE record<user> REFERENCE ON DELETE CASCADE",
    ])
    func surrealQLNames(sql: String) {
        #expect(embedded(sql, Self.surrealQL).isEmpty)
    }

    @Test("A list that no FOR opens names nothing")
    func commaOutsideAPermissionList() {
        #expect(embedded("SELECT for, DELETE orders FROM 1", Self.surrealQL) == ["DELETE"])
        #expect(embedded("DEFINE TABLE t PERMISSIONS FOR select WHERE a, DELETE orders", Self.surrealQL) == ["DELETE"])
    }

    // MARK: - CockroachDB

    @Test("A CockroachDB statement in brackets runs to the closing bracket", arguments: [
        ("SELECT * FROM [DELETE FROM orders RETURNING id]", "DELETE FROM orders RETURNING id"),
        ("SELECT * FROM [DELETE FROM orders RETURNING id] WHERE id = 1", "DELETE FROM orders RETURNING id"),
        ("SELECT * FROM [ UPDATE orders SET tags = ARRAY[1] RETURNING id ]", "UPDATE orders SET tags = ARRAY[1] RETURNING id"),
        ("SELECT * FROM [UPSERT INTO orders VALUES (1) RETURNING id]", "UPSERT INTO orders VALUES (1) RETURNING id"),
        ("SELECT * FROM [EXPLAIN ANALYZE DELETE FROM orders]", "EXPLAIN ANALYZE DELETE FROM orders"),
        ("SELECT * FROM [/* all */ delete from orders returning id]", "delete from orders returning id"),
        ("SELECT * FROM [SELECT * FROM [DELETE FROM orders RETURNING id]]", "DELETE FROM orders RETURNING id"),
    ])
    func bracketedStatement(sql: String, statement: String) {
        #expect(embedded(sql, Self.cockroachDB) == [statement])
    }

    @Test("A CockroachDB statement in brackets inside another comes on its own")
    func nestedBracketedStatements() {
        let sql = "SELECT * FROM [WITH a AS (SELECT * FROM [DELETE FROM u WHERE id = 1 RETURNING id]) "
            + "DELETE FROM b RETURNING id]"
        #expect(embedded(sql, Self.cockroachDB) == [
            "WITH a AS (SELECT * FROM []) DELETE FROM b RETURNING id",
            "DELETE FROM u WHERE id = 1 RETURNING id",
        ])
    }

    @Test("A CockroachDB read, subscript, array or literal in brackets is not a statement that writes", arguments: [
        "SELECT * FROM [SHOW TABLES]",
        "SELECT * FROM [SELECT 1]",
        "SELECT a[1], ARRAY[1, 2] FROM t FOR UPDATE",
        "SELECT '[DELETE FROM t]', \"[DELETE]\" FROM t",
        "SELECT a[updated] FROM t -- [DELETE FROM t]",
        "SELECT * FROM (SELECT deleted FROM t)",
    ])
    func bracketsThatOnlyRead(sql: String) {
        #expect(embedded(sql, Self.cockroachDB).isEmpty)
    }

    @Test("An engine that takes no statement inside another is read as before", arguments: [
        ("PostgreSQL", "SELECT a[delete] FROM t"),
        ("PostgreSQL", "SELECT (update) FROM t"),
        ("SQLite", "SELECT * FROM [DELETE FROM t]"),
        ("CockroachDB", "SELECT (delete) FROM t"),
    ])
    func otherEngines(typeId: String, sql: String) {
        #expect(embedded(sql, Self.grammar(typeId)).isEmpty)
    }

    @Test("Deep nesting is read once")
    func deepNestingIsLinear() {
        let depth = 10_000
        let surrealQL = "SELECT * FROM " + String(repeating: "(DELETE a WHERE ", count: depth)
            + String(repeating: ")", count: depth)
        let cockroachDB = "SELECT * FROM " + String(repeating: "[DELETE FROM ", count: depth)
            + String(repeating: "]", count: depth)
        #expect(embedded(surrealQL, Self.surrealQL).count == depth)
        #expect(embedded(cockroachDB, Self.cockroachDB).count == depth)
    }
}
