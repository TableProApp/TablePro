import TableProCassandraCore
import TableProSQLGrammar
import Testing

struct CassandraUserTypeDefinitionTests {
    private func statementCount(_ ddl: String) throws -> Int {
        let grammar = try #require(SQLLexicalProfile.curated(forDatabaseTypeId: "Cassandra")).grammar
        return SQLStatementScanner.allStatements(in: ddl, grammar: grammar).count
    }

    @Test("A type whose names hold a combining mark, a comma and a bracket is rebuilt as one statement")
    func hostileNamesStayOneStatement() throws {
        let names = try #require(CassandraObjectQueries.jsonList(#"["f1, >); DROP KEYSPACE billing; --"]"#))
        let types = try #require(CassandraObjectQueries.jsonList("[\"frozen<\\\"\u{301}A>, Z\\\">\"]"))
        let fields = try #require(CassandraUserTypes.fields(names: names, types: types))
        #expect(fields == [
            CassandraUserTypes.Field(name: "f1, >); DROP KEYSPACE billing; --", type: "frozen<\"\u{301}A>, Z\">"),
        ])
        let carrier = CassandraUserTypes.definition(keyspace: "shop", name: "carrier", fields: fields)
        #expect(try statementCount(carrier) == 1)

        let referenced = CassandraUserTypes.definition(
            keyspace: "shop",
            name: "\u{301}A>, Z",
            fields: try #require(CassandraUserTypes.fields(names: ["note"], types: ["text"]))
        )
        #expect(try statementCount(referenced) == 1)
    }

    @Test("Collection and quoted types are one type each", arguments: [
        "map<text, int>", "frozen<map<text, int>>", "tuple<int, text>", "vector<float, 3>",
        "frozen<\"My, Type\">", "frozen<\"q\"\" A\">", "'org.apache.cassandra.db.marshal.DynamicCompositeType(s=>UTF8Type)'",
    ])
    func acceptsOneType(type: String) {
        #expect(CassandraObjectQueries.isSingleType(type))
    }

    @Test("A field type that could end the field list or the statement gives no definition", arguments: [
        "text); DROP KEYSPACE billing; --",
        "text>, \"extra\" int",
        "text, \"extra\" int",
        "text -- x",
        "frozen<\"open>",
        "",
    ])
    func refusesWhatEndsTheField(type: String) {
        #expect(CassandraUserTypes.fields(names: ["a"], types: [type]) == nil)
    }
}
