//
//  InspectorSubjectTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Inspector subject")
struct InspectorSubjectTests {
    @Test("A row names its table and its position")
    func rowNamesTableAndPosition() {
        let subject = InspectorSubject.tableRow(
            table: "public.users",
            position: InspectorSubject.RowPosition(index: 12, total: 500)
        )
        #expect(subject.title == "public.users")
        #expect(subject.subtitle?.contains("12") == true)
        #expect(subject.subtitle?.contains("500") == true)
    }

    /// A result of several thousand rows reads as a quantity, the way the grid's own counter does.
    @Test("A large row count is grouped")
    func largeCountsAreGrouped() {
        let subject = InspectorSubject.tableRow(
            table: "t",
            position: InspectorSubject.RowPosition(index: 1, total: 3_503)
        )
        #expect(subject.subtitle?.contains("3") == true)
        #expect(subject.subtitle?.contains("503") == true)
    }

    @Test("A row with no known position drops the second line rather than drawing an empty one")
    func positionlessRowHasNoSubtitle() {
        let subject = InspectorSubject.tableRow(table: "t", position: nil)
        #expect(subject.title == "t")
        #expect(subject.subtitle == nil)
    }

    @Test("A multi-row selection reports how many")
    func multipleRowsReportsCount() {
        let subject = InspectorSubject.multipleRows(table: "t", count: 3)
        #expect(subject.title == "t")
        #expect(subject.subtitle?.contains("3") == true)
    }

    /// A schema grid's selection is a column definition, not a row of a result: it has no position
    /// and no identity, so a subject that assumed one would render "Row 0 of 0" over a good column.
    @Test("A column definition names the column, not a row")
    func columnDefinitionNamesTheColumn() {
        let subject = InspectorSubject.columnDefinition(column: "user_id", table: "public.users")
        #expect(subject.title == "user_id")
        #expect(subject.subtitle?.contains("public.users") == true)
    }

    @Test("A column with no known table still names itself")
    func columnWithoutTable() {
        let subject = InspectorSubject.columnDefinition(column: "user_id", table: nil)
        #expect(subject.title == "user_id")
        #expect(subject.subtitle != nil)
    }

    @Test("A table with no row selected names the table")
    func tableOnly() {
        let subject = InspectorSubject.tableOnly(table: "public.users")
        #expect(subject.title == "public.users")
        #expect(subject.subtitle != nil)
    }

    @Test("An empty subject draws no header at all")
    func emptyDrawsNothing() {
        #expect(InspectorSubject.empty.title == nil)
        #expect(InspectorSubject.empty.subtitle == nil)
    }
}
