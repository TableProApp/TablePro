//
//  RowPayloadCSVEmptyCellTests.swift
//  TableProTests
//
//  An unquoted empty CSV cell is no value; only a quoted "" is an empty string.
//

import Foundation
import Testing

@testable import TablePro

struct RowPayloadCSVEmptyCellTests {
    @Test("An unquoted empty cell leaves its column out of the row")
    func emptyCellIsAbsent() throws {
        let rows = try RowPayload.parseCSV("name,age,note\nBob,,\n")

        #expect(rows == [PayloadRow(values: ["name": .text("Bob")])])
    }

    @Test("A quoted empty cell is an empty string")
    func quotedEmptyCellIsAnEmptyString() throws {
        let rows = try RowPayload.parseCSV("name,age,note\nBob,,\"\"\n")

        #expect(rows == [PayloadRow(values: ["name": .text("Bob"), "note": .text("")])])
    }

    @Test("An empty cell is not inserted as an empty string")
    func emptyCellIsNotInserted() throws {
        let columns = [
            PayloadColumn(name: "name", isPrimaryKey: false, isServerOwned: false),
            PayloadColumn(name: "age", isPrimaryKey: false, isServerOwned: false),
            PayloadColumn(name: "note", isPrimaryKey: false, isServerOwned: false)
        ]
        let planned = try PayloadRowPlanner.values(
            table: "people",
            columns: columns,
            rows: try RowPayload.parseCSV("name,age,note\nBob,,\n")
        )

        #expect(planned.count == 1)
        let inserted = planned.first?.map { $0.column }
        #expect(inserted == ["name"])
    }

    @Test("A record shorter or longer than the header is refused")
    func fieldCountMismatchIsRefused() {
        #expect(throws: IntentDataError.csvFieldCountMismatch(record: 3, found: 1, expected: 3)) {
            _ = try RowPayload.parseCSV("name,age,note\nAda,36,x\nBob\n")
        }
        #expect(throws: IntentDataError.csvFieldCountMismatch(record: 2, found: 4, expected: 3)) {
            _ = try RowPayload.parseCSV("name,age,note\nAda,36,x,extra\n")
        }
    }

    @Test("A blank line between records is skipped")
    func blankLineIsSkipped() throws {
        let rows = try RowPayload.parseCSV("name,age\nAda,36\n\nBob,41\n")

        #expect(rows.count == 2)
    }
}
