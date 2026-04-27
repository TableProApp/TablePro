//
//  SQLParameterExtractorTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class SQLParameterExtractorTests: XCTestCase {
    // MARK: - extractParameters

    func testNoParameters() {
        XCTAssertEqual(SQLParameterExtractor.extractParameters(from: "SELECT 1"), [])
    }

    func testSingleParameter() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT * FROM t WHERE id = :id"),
            ["id"]
        )
    }

    func testMultipleParameters() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "WHERE id = :id AND name = :name"),
            ["id", "name"]
        )
    }

    func testDuplicateParameters() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "WHERE :id = :id OR :name = :id"),
            ["id", "name"]
        )
    }

    func testUnderscoreInName() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "WHERE user_id = :user_id"),
            ["user_id"]
        )
    }

    func testParameterAtEnd() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "WHERE id = :id"),
            ["id"]
        )
    }

    func testDoubleColonCast() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT col::integer FROM t"),
            []
        )
    }

    func testCastFollowedByParameter() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT col::int WHERE id = :id"),
            ["id"]
        )
    }

    func testCastVarcharWithLength() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT col::varchar(255) WHERE id = :id"),
            ["id"]
        )
    }

    func testParameterInSingleQuotes() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT ':name' FROM t"),
            []
        )
    }

    func testParameterInDoubleQuotes() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT \":name\" FROM t"),
            []
        )
    }

    func testParameterInBackticks() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT `:name` FROM t"),
            []
        )
    }

    func testEscapedQuoteInString() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT ':name''s value' FROM t"),
            []
        )
    }

    func testParameterInLineComment() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT 1 -- :name"),
            []
        )
    }

    func testParameterInBlockComment() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT /* :name */ 1"),
            []
        )
    }

    func testParameterAfterComment() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "-- comment\nSELECT :name"),
            ["name"]
        )
    }

    func testBareColon() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT : FROM t"),
            []
        )
    }

    func testColonFollowedByNumber() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT :123 FROM t"),
            []
        )
    }

    func testEmptyString() {
        XCTAssertEqual(SQLParameterExtractor.extractParameters(from: ""), [])
    }

    func testMultipleStatementsParameters() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT :a; SELECT :b"),
            ["a", "b"]
        )
    }

    func testBackslashEscapeInString() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "SELECT '\\:name' FROM t"),
            []
        )
    }

    // MARK: - convertToNativeStyle

    func testConvertToQuestionMark() {
        let params = [
            QueryParameter(name: "id", value: "42", type: .integer),
            QueryParameter(name: "name", value: "Alice", type: .string)
        ]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE id = :id AND name = :name",
            parameters: params,
            style: .questionMark
        )
        XCTAssertEqual(result.sql, "WHERE id = ? AND name = ?")
        XCTAssertEqual(result.values.count, 2)
        XCTAssertEqual(result.values[0] as? String, "42")
        XCTAssertEqual(result.values[1] as? String, "Alice")
    }

    func testConvertToDollar() {
        let params = [
            QueryParameter(name: "id", value: "42"),
            QueryParameter(name: "name", value: "Alice")
        ]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE id = :id AND name = :name",
            parameters: params,
            style: .dollar
        )
        XCTAssertEqual(result.sql, "WHERE id = $1 AND name = $2")
        XCTAssertEqual(result.values.count, 2)
    }

    func testConvertDuplicateParameter() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE :id = :id",
            parameters: params,
            style: .questionMark
        )
        XCTAssertEqual(result.sql, "WHERE ? = ?")
        XCTAssertEqual(result.values.count, 2)
        XCTAssertEqual(result.values[0] as? String, "42")
        XCTAssertEqual(result.values[1] as? String, "42")
    }

    func testConvertNullParameter() {
        let params = [QueryParameter(name: "id", value: "42", isNull: true)]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE id = :id",
            parameters: params,
            style: .questionMark
        )
        XCTAssertEqual(result.sql, "WHERE id = ?")
        XCTAssertEqual(result.values.count, 1)
        XCTAssertNil(result.values[0])
    }

    func testConvertSkipsParameterInString() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "WHERE ':id' = :id",
            parameters: params,
            style: .questionMark
        )
        XCTAssertEqual(result.sql, "WHERE ':id' = ?")
        XCTAssertEqual(result.values.count, 1)
    }

    func testConvertSkipsDoubleColon() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "SELECT col::text WHERE id = :id",
            parameters: params,
            style: .dollar
        )
        XCTAssertEqual(result.sql, "SELECT col::text WHERE id = $1")
        XCTAssertEqual(result.values.count, 1)
    }

    // MARK: - Dollar-Quoted Strings

    func testParameterInDollarQuotedString() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "CREATE FUNCTION foo() AS $$ SELECT :name $$ LANGUAGE sql"),
            []
        )
    }

    func testParameterInTaggedDollarQuotedString() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "DO $body$ SELECT :name $body$"),
            []
        )
    }

    func testParameterAfterDollarQuotedString() {
        XCTAssertEqual(
            SQLParameterExtractor.extractParameters(from: "$$ body $$ SELECT :id"),
            ["id"]
        )
    }

    func testConvertSkipsDollarQuotedString() {
        let params = [QueryParameter(name: "id", value: "42")]
        let result = SQLParameterExtractor.convertToNativeStyle(
            sql: "$$ :id $$ WHERE id = :id",
            parameters: params,
            style: .questionMark
        )
        XCTAssertEqual(result.sql, "$$ :id $$ WHERE id = ?")
        XCTAssertEqual(result.values.count, 1)
    }
}
