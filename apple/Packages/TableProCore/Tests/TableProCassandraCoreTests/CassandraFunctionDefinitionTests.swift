import TableProCassandraCore
import TableProSQLGrammar
import Testing

struct CassandraFunctionDefinitionTests {
    @Test("A function body holding a dollar quote stays one literal", arguments: [
        "return x * 2; // $$; GRANT ALL PERMISSIONS ON ALL KEYSPACES TO mallory; //",
        "return 1; // x$",
        "x $$\u{301}; GRANT ALL PERMISSIONS ON ALL KEYSPACES TO mallory; //",
    ])
    func functionBodyStaysOneLiteral(body: String) throws {
        let ddl = try #require(CassandraObjectQueries.functionDefinition(
            keyspace: "shared",
            name: "twice",
            signature: #"("x" int)"#,
            returnType: "int",
            language: "java",
            body: body,
            calledOnNullInput: false
        ))
        let grammar = try #require(SQLLexicalProfile.curated(forDatabaseTypeId: "Cassandra")).grammar
        #expect(SQLStatementScanner.allStatements(in: ddl, grammar: grammar).count == 1)
    }

    @Test("A return type, language or state type that could end the statement gives no definition")
    func catalogTypeTextIsRefused() {
        let hostile = "int; DROP KEYSPACE billing; --"
        #expect(CassandraObjectQueries.functionDefinition(
            keyspace: "shared", name: "twice", signature: "()", returnType: hostile,
            language: "java", body: "return 1;", calledOnNullInput: false
        ) == nil)
        #expect(CassandraObjectQueries.functionDefinition(
            keyspace: "shared", name: "twice", signature: "()", returnType: "int",
            language: hostile, body: "return 1;", calledOnNullInput: false
        ) == nil)
        #expect(CassandraObjectQueries.aggregateDefinition(
            keyspace: "shared", name: "total", signature: "(int)", stateFunction: "add",
            stateType: hostile, finalFunction: nil
        ) == nil)
    }

    @Test("Argument lists come from the decoded elements, quoted, with each type checked")
    func signatureFromDecodedLists() throws {
        let names = try #require(CassandraObjectQueries.jsonList(#"["x", "y, z", "q\"x"]"#))
        let types = try #require(CassandraObjectQueries.jsonList(#"["int", "map<text, int>", "frozen<\"My, Type\">"]"#))
        #expect(CassandraObjectQueries.signature(argumentNames: names, argumentTypes: types, quotingNames: true)
            == #"("x" int, "y, z" map<text, int>, "q""x" frozen<"My, Type">)"#)
        #expect(CassandraObjectQueries.signature(
            argumentNames: ["x"],
            argumentTypes: ["int) RETURNS NULL ON NULL INPUT RETURNS int LANGUAGE java AS 'x'; DROP KEYSPACE billing; --"]
        ) == nil)
    }

    @Test("A list column read through toJson decodes to its elements, an empty list being null")
    func decodesJSONLists() {
        #expect(CassandraObjectQueries.jsonList(#"["a, b", "q\"x", "plain"]"#) == ["a, b", "q\"x", "plain"])
        #expect(CassandraObjectQueries.jsonList("null")?.isEmpty == true)
        #expect(CassandraObjectQueries.jsonList(nil)?.isEmpty == true)
        #expect(CassandraObjectQueries.jsonList("[a, b]") == nil)
    }
}
