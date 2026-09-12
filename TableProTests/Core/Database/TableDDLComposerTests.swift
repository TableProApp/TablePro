//
//  TableDDLComposerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Table DDL composition")
struct TableDDLComposerTests {
    private let tableDDL = "CREATE TABLE \"app\".\"orders\" (\n    id integer\n)"
    private let comment = "COMMENT ON TABLE \"app\".\"orders\" IS 'Orders table'"
    private let index = "CREATE INDEX idx_orders_day ON \"app\".\"orders\" (day)"

    private func offset(of needle: String, in text: String) throws -> Int {
        let range = try #require(text.range(of: needle), "\(needle) missing from the composition")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    @Test("Comments sit after the table statement and before the indexes, as a dump writes them")
    func commentsSitBetweenTheTableAndItsIndexes() throws {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [index], commentDDL: [comment])

        #expect(try offset(of: "CREATE TABLE", in: composed) < offset(of: "COMMENT ON TABLE", in: composed))
        #expect(try offset(of: "COMMENT ON TABLE", in: composed) < offset(of: "CREATE INDEX", in: composed))
    }

    @Test("Every statement is terminated once, even one the driver already terminated")
    func statementsAreTerminatedOnce() {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL,
            indexDDL: ["\(index);"],
            commentDDL: [comment])

        #expect(composed.contains("IS 'Orders table';"))
        #expect(!composed.contains("IS 'Orders table';;"))
        #expect(composed.contains("(day);"))
        #expect(!composed.contains("(day);;"))
    }

    @Test("The preamble stays first")
    func preambleStaysFirst() throws {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL,
            indexDDL: [],
            commentDDL: [comment],
            preamble: "CREATE SEQUENCE orders_id_seq;")

        #expect(try offset(of: "CREATE SEQUENCE", in: composed) < offset(of: "CREATE TABLE", in: composed))
        #expect(try offset(of: "CREATE TABLE", in: composed) < offset(of: "COMMENT ON TABLE", in: composed))
    }

    @Test("An empty comment list composes exactly as it did before comments existed")
    func emptyCommentListChangesNothing() {
        let withComments = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [index], commentDDL: [])
        let withoutComments = TableDDLComposer.compose(tableDDL: tableDDL, indexDDL: [index])

        #expect(withComments == withoutComments)
    }

    @Test("Comments alone still terminate the table statement and stand in their own block")
    func commentsAloneComposeWithoutIndexes() {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [], commentDDL: [comment])

        #expect(composed == "\(tableDDL);\n\n\(comment);")
    }

    @Test("A blank comment statement is dropped rather than written as an empty line")
    func blankStatementsAreDropped() {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [], commentDDL: ["", "   \n"])

        #expect(composed == tableDDL)
    }
}
