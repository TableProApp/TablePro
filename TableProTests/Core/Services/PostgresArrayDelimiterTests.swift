//
//  PostgresArrayDelimiterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PostgresArrayDelimiterTests {
    private let classifier = ColumnTypeClassifier()

    /// Measured on PostgreSQL 17.11: `SELECT typname FROM pg_type WHERE typdelim <> ','` returns
    /// `box` and its array and nothing else, so every other element type takes the comma.
    @Test("Only box declares a delimiter of its own")
    func resolvesTheElementDelimiter() {
        #expect(PostgresArrayDelimiter.forElementType("box") == ";")
        #expect(PostgresArrayDelimiter.forElementType("BOX") == ";")
        #expect(PostgresArrayDelimiter.forElementType("pg_catalog.box") == ";")
        #expect(PostgresArrayDelimiter.forElementType("text") == ",")
        #expect(PostgresArrayDelimiter.forElementType("numeric(10,2)") == ",")
        #expect(PostgresArrayDelimiter.forElementType(nil) == ",")
        #expect(PostgresArrayDelimiter.forElementType("") == ",")
    }

    @Test("The delimiter comes from the column's element, not the column")
    func resolvesFromTheColumnsElement() {
        #expect(PostgresArrayDelimiter.forColumn(classifier.classify(rawTypeName: "box[]")) == ";")
        #expect(PostgresArrayDelimiter.forColumn(classifier.classify(rawTypeName: "text[]")) == ",")
        #expect(PostgresArrayDelimiter.forColumn(classifier.classify(rawTypeName: "box")) == ",")
    }

    /// A box's own text holds commas, so reading a `box[]` with the comma splits one box into four
    /// fragments and the editor commits `{4),(1,2)}`, which PostgreSQL rejects. These two literals
    /// came off a live server.
    @Test("A box array round-trips with its own delimiter")
    func roundTripsABoxArray() throws {
        let delimiter = PostgresArrayDelimiter.forColumn(classifier.classify(rawTypeName: "box[]"))

        let one = "{(3,4),(1,2)}"
        let parsedOne = try #require(PostgresArrayLiteralCodec.parse(one, delimiter: delimiter))
        #expect(parsedOne == [.value("(3,4),(1,2)")])
        #expect(PostgresArrayLiteralCodec.serialize(parsedOne, delimiter: delimiter) == one)

        let two = "{(3,4),(1,2);(7,8),(5,6)}"
        let parsedTwo = try #require(PostgresArrayLiteralCodec.parse(two, delimiter: delimiter))
        #expect(parsedTwo == [.value("(3,4),(1,2)"), .value("(7,8),(5,6)")])
        #expect(PostgresArrayLiteralCodec.serialize(parsedTwo, delimiter: delimiter) == two)
    }

    @Test("Read with the comma, the same literal splits into fragments")
    func showsWhatTheCommaDid() throws {
        let parsed = try #require(PostgresArrayLiteralCodec.parse("{(3,4),(1,2)}"))
        #expect(parsed == [.value("(3"), .value("4)"), .value("(1"), .value("2)")])
    }
}
