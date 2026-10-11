//
//  EtcdCommandArgumentTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct EtcdCommandArgumentRoundTripTests {
    private static let arguments = [
        "",
        "plain",
        "a b",
        "\u{301}x/",
        "\u{301} mark after a space",
        "\u{600} b",
        "x\"\u{301} --prefix",
        "\"\u{301}",
        "\\\u{301}",
        "tab\there",
        "line\nbreak",
        "carriage\rreturn",
        "'single'",
        "C:\\path"
    ]

    @Test("A quoted argument reads back as the same key, scalar for scalar", arguments: arguments)
    func delReadsBackTheSameKey(argument: String) throws {
        let operation = try EtcdCommandParser.parse("del \(EtcdCommandArgument.quoted(argument))")

        guard case let .del(key, prefix) = operation else {
            Issue.record("Expected a del operation, got \(operation)")
            return
        }
        #expect(Array(key.unicodeScalars) == Array(argument.unicodeScalars))
        #expect(!prefix)
    }

    @Test("A quoted key and value read back whole from a put", arguments: arguments)
    func putReadsBackKeyAndValue(argument: String) throws {
        let key = "k" + argument
        let statement = "put \(EtcdCommandArgument.quoted(key)) \(EtcdCommandArgument.quoted(argument))"

        guard case let .put(parsedKey, parsedValue, leaseId) = try EtcdCommandParser.parse(statement) else {
            Issue.record("Expected a put operation from \(statement)")
            return
        }
        #expect(Array(parsedKey.unicodeScalars) == Array(key.unicodeScalars))
        #expect(Array(parsedValue.unicodeScalars) == Array(argument.unicodeScalars))
        #expect(leaseId == nil)
    }

    @Test("Deleting a row whose key starts with a combining mark deletes that key")
    func rowDeleteKeepsLeadingCombiningMark() throws {
        let generator = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["\u{301}x", "v", "1", "1", "1", "0"]
        )

        let writes = try generator.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        let statement = try #require(writes.first?.statement)
        guard case let .del(key, prefix) = try EtcdCommandParser.parse(statement) else {
            Issue.record("Expected a del operation from \(statement)")
            return
        }
        #expect(Array(key.unicodeScalars) == Array("\u{301}x".unicodeScalars))
        #expect(!prefix)
    }
}
