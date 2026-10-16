//
//  CellEntryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct CellEntryTests {
    private static let timestamp = ColumnType.timestamp(rawType: "timestamptz")

    private static func staged(
        _ text: String,
        _ columnType: ColumnType?,
        on databaseType: DatabaseType = .postgresql,
        writer: CellWriterSupport = .host
    ) -> PluginCellValue? {
        CellEntry.typed(text, columnType: columnType, databaseType: databaseType, writer: writer)?.value
    }

    @Test("A function typed in any case and spacing stages the vocabulary's own spelling as SQL")
    func typedFunctionIsCanonical() throws {
        let entry = try #require(
            CellEntry.typed(" NOW() ", columnType: Self.timestamp, databaseType: .postgresql, writer: .host)
        )

        #expect(entry.value == .text("now()"))
        #expect(entry.isExpression)
    }

    @Test("An alias stages the canonical spelling it stands for")
    func aliasIsCanonical() {
        #expect(Self.staged("CURRENT_DATE", .date(rawType: "DATE"), on: .mysql) == .text("CURDATE()"))
    }

    @Test("The same text on a column of another kind is a literal")
    func otherKindIsLiteral() {
        #expect(Self.staged("now()", .text(rawType: "text")) == nil)
        #expect(Self.staged("CURRENT_DATE", Self.timestamp) == nil)
        #expect(Self.staged("now()", nil) == nil)
    }

    @Test("A writer that does not take SQL in a cell gets nothing, so its own handling of the text stays")
    func writerWithoutExpressions() {
        let uuidOnly = CellWriterSupport(acceptsExpressions: false, acceptsUUIDText: true)

        #expect(Self.staged("now()", Self.timestamp, writer: .none) == nil)
        #expect(Self.staged("now()", Self.timestamp, writer: uuidOnly) == nil)
    }

    @Test("An engine the vocabulary does not list takes no function")
    func unknownEngine() {
        #expect(Self.staged("now()", Self.timestamp, on: DatabaseType(rawValue: "SomePluginEngine")) == nil)
    }

    @Test("Text that only contains a function name is a literal")
    func partialMatchIsLiteral() {
        #expect(Self.staged("now() + 1", Self.timestamp) == nil)
        #expect(Self.staged("", Self.timestamp) == nil)
    }
}
