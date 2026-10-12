//
//  CellFilterMenuBuilderTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct CellFilterMenuBuilderTests {
    private func operators(
        _ value: PluginCellValue,
        type: ColumnType? = .text(rawType: "VARCHAR(255)")
    ) -> [FilterOperator] {
        CellFilterMenuBuilder.conditions(columnName: "status", columnType: type, value: value)
            .map(\.filterOperator)
    }

    @Test("A text value offers equals and not equals with the raw value")
    func textValue() {
        let filters = CellFilterMenuBuilder.conditions(
            columnName: "status", columnType: .text(rawType: "VARCHAR(255)"), value: "paid"
        )

        #expect(filters.map(\.filterOperator) == [.equal, .notEqual])
        #expect(filters.allSatisfy { $0.columnName == "status" && $0.value == "paid" && $0.isValid })
        #expect(filters.allSatisfy { $0.isCaseSensitive })
    }

    @Test("Numbers and dates also offer greater than and less than")
    func orderedValues() {
        let ordered: [ColumnType] = [
            .integer(rawType: "INT"), .decimal(rawType: "NUMERIC"), .date(rawType: "DATE"),
            .timestamp(rawType: "TIMESTAMPTZ"), .datetime(rawType: "DATETIME")
        ]
        for type in ordered {
            #expect(operators("42", type: type) == [.equal, .notEqual, .greaterThan, .lessThan], "\(type)")
        }
        #expect(operators("true", type: .boolean(rawType: "bool")) == [.equal, .notEqual])
        #expect(operators("a", type: .enumType(rawType: "ENUM", values: ["a"])) == [.equal, .notEqual])
    }

    @Test("A NULL cell offers is NULL and is not NULL whatever its type")
    func nullValue() {
        #expect(operators(.null) == [.isNull, .isNotNull])
        #expect(operators(.null, type: .json(rawType: "json")) == [.isNull, .isNotNull])
        #expect(operators(.null, type: nil) == [.isNull, .isNotNull])
    }

    @Test("An empty text cell offers is empty and is not empty on a text column only")
    func emptyValue() {
        #expect(operators("") == [.isEmpty, .isNotEmpty])
        #expect(operators("", type: .integer(rawType: "INT")).isEmpty)
        #expect(operators("", type: .json(rawType: "json")).isEmpty)
        #expect(operators("", type: nil).isEmpty)
    }

    @Test("A value the filter would change offers nothing")
    func valuesThatDoNotRoundTrip() {
        #expect(operators("  paid").isEmpty, "the SQL generators trim the value")
        #expect(operators("paid ").isEmpty)
        #expect(operators("   ").isEmpty)
        #expect(operators("NULL", type: .integer(rawType: "INT")).isEmpty, "renders as IS NULL")
        #expect(operators("null", type: .timestamp(rawType: "TIMESTAMP")).isEmpty)
        #expect(operators("paid", type: nil).isEmpty, "an unresolved type has its literals guessed")
    }

    @Test("The word NULL in a text column is an ordinary value")
    func nullWordInTextColumn() {
        #expect(operators("NULL") == [.equal, .notEqual])
    }

    @Test("Columns without an equality comparison offer nothing")
    func typesWithoutEquality() {
        #expect(operators("{\"a\":1}", type: .json(rawType: "json")).isEmpty)
        #expect(operators("x", type: .text(rawType: "CLOB")).isEmpty)
        #expect(operators("x", type: .text(rawType: "xml")).isEmpty)
        #expect(operators("POINT(1 2)", type: .spatial(rawType: "GEOMETRY")).isEmpty)
        #expect(operators("{1,2}", type: .array(rawType: "int[]", element: .integer(rawType: "int"))).isEmpty)
        #expect(operators(.bytes(Data([0x01, 0x02])), type: .blob(rawType: "BLOB")).isEmpty)
    }

    @Test("A value over the length cap offers nothing")
    func overlongValue() {
        let atCap = String(repeating: "x", count: CellFilterMenuBuilder.maxValueLength)
        #expect(operators(.text(atCap)) == [.equal, .notEqual])
        #expect(operators(.text(atCap + "x")).isEmpty)
    }

    @Test("Special characters are kept verbatim for the SQL generator to escape")
    func specialCharactersKept() {
        let value = "O'Brien 100% _x_ \\n"
        let filters = CellFilterMenuBuilder.conditions(
            columnName: "name", columnType: .text(rawType: "TEXT"), value: .text(value)
        )
        #expect(filters.map(\.value) == [value, value])
    }

    @Test("Menu titles read as the condition, on one line and cut short")
    func titles() throws {
        let item = try #require(CellFilterMenuBuilder.menuItem(
            columnName: "amount", columnType: .decimal(rawType: "NUMERIC"), value: "10.50"
        ) { _ in })
        let submenu = try #require(item.submenu)

        #expect(item.title == "Filter")
        #expect(submenu.items.map(\.title) == [
            "amount = “10.50”", "amount != “10.50”", "amount > “10.50”", "amount < “10.50”"
        ])
        #expect(submenu.items.allSatisfy { $0.keyEquivalent.isEmpty && $0.submenu == nil && !$0.isAlternate })

        let multiLine = "first line\nsecond line and a good deal more text"
        let long = try #require(CellFilterMenuBuilder.menuItem(
            columnName: "notes", columnType: .text(rawType: "TEXT"), value: .text(multiLine)
        ) { _ in })
        let title = try #require(long.submenu?.items.first?.title)
        #expect(!title.contains { $0.isNewline })
        #expect(title.hasSuffix("…”"))
    }

    @Test("A cell with nothing to offer gets no Filter item")
    func noItemWithoutConditions() {
        let item = CellFilterMenuBuilder.menuItem(
            columnName: "payload", columnType: .json(rawType: "json"), value: "{}"
        ) { _ in }
        #expect(item == nil)
    }

    @Test("Choosing a condition hands that filter to the apply action")
    func choosingAppliesTheFilter() throws {
        var applied: [TableFilter] = []
        let item = try #require(CellFilterMenuBuilder.menuItem(
            columnName: "status", columnType: .text(rawType: "TEXT"), value: "paid"
        ) { applied.append($0) })
        let submenu = try #require(item.submenu)

        submenu.performActionForItem(at: 1)

        #expect(applied.count == 1)
        #expect(applied.first?.filterOperator == .notEqual)
        #expect(applied.first?.value == "paid")
    }
}
