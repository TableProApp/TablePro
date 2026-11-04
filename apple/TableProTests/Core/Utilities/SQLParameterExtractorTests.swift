//
//  SQLParameterExtractorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
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
        #expect((result.values[0] as? String) == "42")
        #expect((result.values[1] as? String) == "Alice")
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
        #expect((result.values[0] as? String) == "42")
        #expect((result.values[1] as? String) == "42")
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
}
