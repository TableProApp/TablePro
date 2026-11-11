//
//  SQLParameterExtractorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct SQLParameterExtractorTests {
    // MARK: - extractParameters

    @Test
    func noParameters() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT 1") == [])
    }

    @Test
    func singleParameter() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT * FROM t WHERE id = :id") == ["id"])
    }

    @Test
    func multipleParameters() {
        #expect(SQLParameterExtractor.extractParameters(from: "WHERE id = :id AND name = :name") == ["id", "name"])
    }

    @Test
    func duplicateParameters() {
        #expect(SQLParameterExtractor.extractParameters(from: "WHERE :id = :id OR :name = :id") == ["id", "name"])
    }

    @Test
    func underscoreInName() {
        #expect(SQLParameterExtractor.extractParameters(from: "WHERE user_id = :user_id") == ["user_id"])
    }

    @Test
    func parameterAtEnd() {
        #expect(SQLParameterExtractor.extractParameters(from: "WHERE id = :id") == ["id"])
    }

    @Test
    func doubleColonCast() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT col::integer FROM t") == [])
    }

    @Test
    func castFollowedByParameter() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT col::int WHERE id = :id") == ["id"])
    }

    @Test
    func castVarcharWithLength() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT col::varchar(255) WHERE id = :id") == ["id"])
    }

    @Test
    func parameterInSingleQuotes() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT ':name' FROM t") == [])
    }

    @Test
    func parameterInDoubleQuotes() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT \":name\" FROM t") == [])
    }

    @Test
    func parameterInBackticks() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT `:name` FROM t") == [])
    }

    @Test
    func escapedQuoteInString() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT ':name''s value' FROM t") == [])
    }

    @Test
    func parameterInLineComment() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT 1 -- :name") == [])
    }

    @Test
    func parameterInBlockComment() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT /* :name */ 1") == [])
    }

    @Test
    func parameterAfterComment() {
        #expect(SQLParameterExtractor.extractParameters(from: "-- comment\nSELECT :name") == ["name"])
    }

    @Test
    func bareColon() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT : FROM t") == [])
    }

    @Test
    func colonFollowedByNumber() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT :123 FROM t") == [])
    }

    @Test
    func emptyString() {
        #expect(SQLParameterExtractor.extractParameters(from: "") == [])
    }

    @Test
    func multipleStatementsParameters() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT :a; SELECT :b") == ["a", "b"])
    }

    @Test
    func backslashEscapeInString() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT '\\:name' FROM t") == [])
    }

    // MARK: - convertToNativeStyle

    @Test
    func convertToQuestionMark() {
        let params = [
            QueryParameter(name: "id", value: "42", type: .integer),
            QueryParameter(name: "name", value: "Alice", type: .string)
        ]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE id = :id AND name = :name",
            parameters: params,
            style: .questionMark
        )
        #expect(result.sql == "WHERE id = ? AND name = ?")
        #expect(result.values.count == 2)
        #expect((result.values[0] as? TypedParameterValue) == TypedParameterValue(text: "42", kind: .integer))
        #expect((result.values[1] as? TypedParameterValue) == TypedParameterValue(text: "Alice", kind: .text))
    }

    @Test("A String parameter holding a plain number keeps the reading by shape; any other text is text", arguments: [
        ("42", PluginColumnKind?.none), ("-3.5", nil), ("00123", nil), ("1E5", .text), ("12e3", .text), ("1.", .text),
        (".5", nil), ("abc", .text), ("", .text), ("-", .text),
    ])
    func stringKindFollowsTheValue(value: String, kind: PluginColumnKind?) {
        #expect(QueryParameterType.string.pluginKind(for: value) == kind)
    }

    @Test
    func convertToDollar() {
        let params = [
            QueryParameter(name: "id", value: "42"),
            QueryParameter(name: "name", value: "Alice")
        ]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE id = :id AND name = :name",
            parameters: params,
            style: .dollar
        )
        #expect(result.sql == "WHERE id = $1 AND name = $2")
        #expect(result.values.count == 2)
    }

    @Test
    func convertDuplicateParameter() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE :id = :id",
            parameters: params,
            style: .questionMark
        )
        #expect(result.sql == "WHERE ? = ?")
        #expect(result.values.count == 2)
        #expect((result.values[0] as? TypedParameterValue)?.text == "42")
        #expect((result.values[1] as? TypedParameterValue)?.text == "42")
    }

    @Test
    func convertNullParameter() {
        let params = [QueryParameter(name: "id", value: "42", isNull: true)]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE id = :id",
            parameters: params,
            style: .questionMark
        )
        #expect(result.sql == "WHERE id = ?")
        #expect(result.values.count == 1)
        #expect(result.values[0] == nil)
    }

    @Test
    func convertSkipsParameterInString() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE ':id' = :id",
            parameters: params,
            style: .questionMark
        )
        #expect(result.sql == "WHERE ':id' = ?")
        #expect(result.values.count == 1)
    }

    @Test
    func convertSkipsDoubleColon() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "SELECT col::text WHERE id = :id",
            parameters: params,
            style: .dollar
        )
        #expect(result.sql == "SELECT col::text WHERE id = $1")
        #expect(result.values.count == 1)
    }

    // MARK: - Dollar-Quoted Strings

    @Test
    func parameterInDollarQuotedString() {
        #expect(SQLParameterExtractor.extractParameters(from: "CREATE FUNCTION foo() AS $$ SELECT :name $$ LANGUAGE sql") == [])
    }

    @Test
    func parameterInTaggedDollarQuotedString() {
        #expect(SQLParameterExtractor.extractParameters(from: "DO $body$ SELECT :name $body$") == [])
    }

    @Test
    func canonicallyEquivalentTagDoesNotCloseDollarQuotedString() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT $K$ x $\u{212A}$ :name $K$, :id") == ["id"])
    }

    @Test
    func parameterAfterDollarQuotedString() {
        #expect(SQLParameterExtractor.extractParameters(from: "$$ body $$ SELECT :id") == ["id"])
    }

    @Test
    func convertSkipsDollarQuotedString() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "$$ :id $$ WHERE id = :id",
            parameters: params,
            style: .questionMark
        )
        #expect(result.sql == "$$ :id $$ WHERE id = ?")
        #expect(result.values.count == 1)
    }

    // MARK: - Engine grammar

    @Test(
        "A colon written against a name, a literal, a subscript or a call is the engine's own syntax",
        arguments: [
            "SELECT src:customer.name FROM raw",
            "SELECT arr[lo:hi] FROM t",
            "SELECT {id:UInt32}",
            "SELECT \"src\":customer FROM raw",
            "SELECT f(x):y FROM t",
            "SELECT '{}'::jsonb, a::int",
        ]
    )
    func colonAfterOperandIsNotAParameter(sql: String) {
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .ansi) == [])
    }

    @Test
    func parameterBesidePathAndCast() {
        let sql = "SELECT src:customer, :id::int FROM raw WHERE a = :id AND b IN (:b, :c)"
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .ansi) == ["id", "b", "c"])
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: sql,
            parameters: [QueryParameter(name: "id", value: "1")],
            style: .dollar,
            grammar: .ansi
        )
        #expect(result.sql == "SELECT src:customer, $1::int FROM raw WHERE a = $2 AND b IN ($3, $4)")
    }

    @Test
    func backslashEndsALiteralOnlyWhereTheEngineEscapesWithIt() {
        let sql = "SELECT 'C:\\' AS p, :id"
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .ansi) == ["id"])
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .backslashEscapesInSingleQuotes) == [])
    }

    @Test
    func bracketNameHidesAColonOnlyWhereBracketsQuote() {
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT [a :b] FROM t", grammar: .bracketQuotedIdentifiers) == [])
        #expect(SQLParameterExtractor.extractParameters(from: "SELECT x[ :b] FROM t", grammar: .ansi) == ["b"])
    }

    @Test
    func hashCommentHidesAColonOnlyWhereTheEngineReadsOne() {
        let sql = "SELECT 1 # :a\n, :b"
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .hashLineComments) == ["b"])
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .ansi) == ["a", "b"])
    }

    @Test
    func bindGluedToAKeywordIsAParameter() {
        let extract = { (sql: String) in SQLParameterExtractor.extractParameters(from: sql, grammar: .ansi) }
        #expect(extract("SELECT * FROM t LIMIT:n OFFSET:m") == ["n", "m"])
        #expect(extract("SELECT * FROM t ORDER BY id DESC LIMIT 10 OFFSET:m") == ["m"])
        #expect(extract("SELECT * FROM (SELECT 1) s LIMIT:n") == ["n"])
        #expect(extract("DELETE FROM t LIMIT:n") == ["n"])
        #expect(extract("SELECT * FROM t LIMIT ALL OFFSET:m") == ["m"])
        #expect(extract("SELECT a FROM t GROUP BY ALL LIMIT:n") == ["n"])
        #expect(extract("SELECT * FROM t WHERE id IN:ids") == ["ids"])
        #expect(extract("SELECT * FROM t WHERE a BETWEEN:lo AND:hi") == ["lo", "hi"])
        #expect(extract("SELECT CASE WHEN:c THEN:p ELSE:q END") == ["c", "p", "q"])
        #expect(extract("SELECT * FROM t WHERE name LIKE:pat OR:x") == ["pat", "x"])
    }

    @Test(
        "A row-limit word in an operand's place is a column, so its colon stays a path",
        arguments: [
            "SELECT limit:currency FROM raw",
            "SELECT a, offset:x FROM raw",
            "SELECT t.limit:x FROM raw t",
            "SELECT DISTINCT limit:x FROM raw",
            "SELECT * FROM raw WHERE limit:x > 1",
            "SELECT src:in:x FROM raw",
            "SELECT * FROM t LIMIT {limit:UInt32}",
            "SELECT a FROM t WHERE a IS DISTINCT FROM limit:x",
            "SELECT EXTRACT(YEAR FROM limit:ts) FROM raw",
            "SELECT ALL limit:x FROM raw",
            "SELECT TOP 10 limit:currency FROM raw",
        ]
    )
    func rowLimitWordAsAColumnKeepsItsPath(sql: String) {
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .ansi) == [])
    }

    @Test
    func bindGluedToAKeywordIsSpacedFromIt() {
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "SELECT * FROM t WHERE id IN(:a) LIMIT:n",
            parameters: [QueryParameter(name: "a", value: "1"), QueryParameter(name: "n", value: "5")],
            style: .dollar,
            grammar: .ansi
        )
        #expect(result.sql == "SELECT * FROM t WHERE id IN($1) LIMIT $2")
        #expect(result.values.count == 2)
    }

    @Test
    func nestedCommentHidesAColon() {
        let sql = "/* a /* b */ :x */ SELECT :y"
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .nestedBlockComments) == ["y"])
        #expect(SQLParameterExtractor.extractParameters(from: sql, grammar: .ansi) == ["x", "y"])
    }
}
