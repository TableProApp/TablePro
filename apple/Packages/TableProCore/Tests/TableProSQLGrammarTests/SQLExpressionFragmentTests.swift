import TableProSQLGrammar
import Testing

struct SQLExpressionFragmentTests {
    @Test("A catalog expression that is one expression is accepted", arguments: [
        ("SQL Server", "((0))"),
        ("SQL Server", "(getdate())"),
        ("SQL Server", "('a;b--c')"),
        ("SQL Server", "(N'x]y')"),
        ("PostgreSQL", "'{}'::integer[]"),
        ("PostgreSQL", "nextval('s'::regclass)"),
        ("MySQL", "concat(`c`, 'a''b')"),
        ("DuckDB", "x + 1"),
        ("Trino", "row(x integer, y decimal(10, 2))"),
        ("PostgreSQL", "ARRAY[1, 2]"),
        ("DuckDB", "[1, 2]"),
        ("DuckDB", "{'a': 1, 'b': 2}"),
        ("MySQL", "CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP"),
        ("SQL Server", "(CONVERT([bit],(0)))"),
    ])
    func acceptsOneExpression(typeId: String, text: String) {
        #expect(SQLExpressionFragment.isSingleExpression(text, databaseTypeId: typeId))
    }

    @Test("A catalog expression that could end its clause is refused", arguments: [
        ("SQL Server", "((0)); DROP TABLE t"),
        ("SQL Server", "((0)) DROP TABLE t"),
        ("SQL Server", "(0)\nGO\nDROP TABLE t"),
        ("SQL Server", "(0) -- x"),
        ("SQL Server", "(0) /* x */"),
        ("SQL Server", "('x"),
        ("SQL Server", "(0))"),
        ("SQL Server", "((0)"),
        ("SQL Server", ""),
        ("SQL Server", "   "),
        ("PostgreSQL", "1); DROP TABLE t; --"),
        ("PostgreSQL", "$$x"),
        ("MySQL", "'a\\'); DROP TABLE t; -- '"),
        ("MySQL", "1 # x"),
        ("MySQL", "/*!50000 1 */"),
        ("MySQL", "0x00, DROP COLUMN secret"),
        ("Oracle", "1\n/"),
        ("DuckDB", "[1, 2]; DROP TABLE t"),
        ("DuckDB", "[1, 2), (3"),
        ("SQL Server", "(0), CONSTRAINT [x] CHECK (1=0)"),
        ("Trino", #"row(x integer), "id" = (0 integer)"#),
        ("Trino", "row(x integer)); DROP TABLE lake.default.orders; SELECT (1 -- integer)"),
        ("SQL Server", "('" + String(repeating: "A", count: 3_998)),
    ])
    func refusesWhatCanEndTheClause(typeId: String, text: String) {
        #expect(!SQLExpressionFragment.isSingleExpression(text, databaseTypeId: typeId))
    }

    @Test("Catalog text that is one string literal is recognised", arguments: ["'x'", "N'it''s'", "''"])
    func recognisesOneStringLiteral(text: String) {
        #expect(SQLExpressionFragment.isSingleStringLiteral(text, databaseTypeId: "SAP HANA"))
    }

    @Test("Catalog text that only starts like a string literal is not one", arguments: [
        #"'x'); DROP TABLE "SHOP"."ORDERS"; CREATE COLUMN TABLE "SHOP"."Z" ("A" INTEGER"#,
        "'a' || 'b'",
        "'open",
        "\"name\"",
        "x",
        "z'abc'",
    ])
    func refusesWhatOnlyStartsLikeOne(text: String) {
        #expect(!SQLExpressionFragment.isSingleStringLiteral(text, databaseTypeId: "SAP HANA"))
    }

    @Test("A type with angle brackets is one type, and one that closes early is not")
    func typeText() {
        #expect(SQLExpressionFragment.isSingleType("frozen<map<text, int>>", databaseTypeId: "Cassandra"))
        #expect(SQLExpressionFragment.isSingleType("tuple<int, text>", databaseTypeId: "Cassandra"))
        #expect(SQLExpressionFragment.isSingleType("struct<a: int, b: list<string>>", databaseTypeId: "Cloudflare R2 SQL"))
        #expect(!SQLExpressionFragment.isSingleType("INT64 DEFAULT 1 < 2, x INT64 DEFAULT 3 > 2", databaseTypeId: "BigQuery"))
        #expect(!SQLExpressionFragment.isSingleType("map<text, int>>, x int); DROP KEYSPACE k; --", databaseTypeId: "Cassandra"))
        #expect(!SQLExpressionFragment.isSingleType("int, \"x\" text", databaseTypeId: "Cassandra"))
        #expect(!SQLExpressionFragment.isSingleExpression("map<text, int>", databaseTypeId: "Cassandra"))
    }

    // DuckDB 1.5.4 ran the first one inside CREATE TABLE and created column `extra`.
    @Test("Where `<` only compares, a comma between it and a `>` still ends the type", arguments: [
        ("DuckDB", "BOOLEAN DEFAULT 1 < 2, extra BOOLEAN DEFAULT 3 > 2"),
        ("Dameng", "BOOLEAN DEFAULT 1 < 2, extra BOOLEAN DEFAULT 3 > 2"),
        ("Dameng", "NUMBER DEFAULT CASE WHEN 1 < 2 THEN 1 END, X NUMBER DEFAULT CASE WHEN 3 > 2 THEN 1 END"),
    ])
    func comparisonIsNotATypeBracket(typeId: String, text: String) {
        #expect(!SQLExpressionFragment.isSingleType(text, databaseTypeId: typeId))
    }

    @Test("A query body may hold top-level commas but still only one statement")
    func queryBody() {
        #expect(SQLExpressionFragment.isSingleQuery("SELECT a, b FROM t", databaseTypeId: "DuckDB"))
        #expect(!SQLExpressionFragment.isSingleQuery("SELECT 1; DROP TABLE t", databaseTypeId: "DuckDB"))
        #expect(!SQLExpressionFragment.isSingleQuery("SELECT 1 -- x", databaseTypeId: "DuckDB"))
        #expect(SQLExpressionFragment.isSingleQuery("SELECT a -- the key\nFROM t /* c */", databaseTypeId: "DuckDB"))
        #expect(!SQLExpressionFragment.isSingleQuery("SELECT 1 /* open", databaseTypeId: "DuckDB"))
    }

    @Test("A comment stored after a default is dropped, and what is left is checked as usual")
    func strippingComments() {
        let stored = SQLExpressionFragment.strippingComments("'NEW' -- initial\n", databaseTypeId: "Oracle")
        #expect(stored == "'NEW'")
        #expect(SQLExpressionFragment.isSingleExpression(stored, databaseTypeId: "Oracle"))
        let hostile = SQLExpressionFragment.strippingComments("1 /* x */, b NUMBER", databaseTypeId: "Oracle")
        #expect(!SQLExpressionFragment.isSingleExpression(hostile, databaseTypeId: "Oracle"))
        #expect(SQLExpressionFragment.strippingComments("'a -- b'", databaseTypeId: "Oracle") == "'a -- b'")
    }
}
