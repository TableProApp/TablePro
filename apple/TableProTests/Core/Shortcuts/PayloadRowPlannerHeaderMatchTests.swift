//
//  PayloadRowPlannerHeaderMatchTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct PayloadRowPlannerHeaderMatchTests {
    private func columns(_ names: [String]) -> [PayloadColumn] {
        names.map { PayloadColumn(name: $0, isPrimaryKey: false, isServerOwned: false) }
    }

    private func planned(_ rows: [PayloadRow], into names: [String]) throws -> [[String]] {
        try PayloadRowPlanner.values(table: "people", columns: columns(names), rows: rows)
            .map { row in row.map { "\($0.column)=\($0.value ?? "NULL")" } }
    }

    // SQL Server exports its headers bracketed, and Shortcuts has no sheet to map them by hand.
    @Test("A CSV with bracketed headers inserts into the columns they name")
    func bracketedHeadersFindTheirColumns() async throws {
        let rows = try await RowPayload.parse(data: "[id],[name]\n1,Bob\n", file: nil)
        #expect(try planned(rows, into: ["id", "name"]) == [["id=1", "name=Bob"]])
    }

    @Test("A doubled closing bracket inside the brackets is one bracket of the name")
    func doubledBracketIsUnescaped() throws {
        let row = PayloadRow(values: ["[a]]b]": .text("x")])
        #expect(try planned([row], into: ["a]b"]) == [["a]b=x"]])
    }

    @Test("A lone closing bracket inside means the key is not a bracketed name")
    func loneBracketIsNotUnwrapped() {
        #expect(throws: IntentDataError.unknownColumns(["[a]b]"], "people")) {
            _ = try planned([PayloadRow(values: ["[a]b]": .text("x")])], into: ["a]b"])
        }
    }

    @Test("A key differing only in case finds its column, as the import sheet matches headers")
    func caseInsensitiveMatch() throws {
        #expect(try planned([PayloadRow(values: ["Name": .text("Ada")])], into: ["name"]) == [["name=Ada"]])
    }

    @Test("A case match two columns share is refused rather than guessed")
    func ambiguousCaseMatchIsUnknown() {
        #expect(throws: IntentDataError.unknownColumns(["NAME"], "people")) {
            _ = try planned([PayloadRow(values: ["NAME": .text("Ada")])], into: ["Name", "name"])
        }
    }

    @Test("A key spelled exactly claims its column before a bracketed one can")
    func exactSpellingClaimsFirst() {
        #expect(throws: IntentDataError.unknownColumns(["[id]"], "people")) {
            _ = try planned([PayloadRow(values: ["id": .text("1"), "[id]": .text("2")])], into: ["id"])
        }
    }
}
