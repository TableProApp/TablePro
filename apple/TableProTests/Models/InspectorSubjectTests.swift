//
//  InspectorSubjectTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

    // A result of several thousand rows reads as a quantity, the way the grid's own counter does.
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

    @Test("A column definition names the column and its table")
    func columnDefinitionNamesTheColumn() {
        let subject = InspectorSubject.definition(name: "user_id", section: .columns, table: "users")
        #expect(subject.title == "user_id")
        #expect(subject.subtitle == String(format: String(localized: "Column of %@"), "users"))
    }

    @Test("An index names itself as an index, not a column")
    func indexIsNotAColumn() {
        let subject = InspectorSubject.definition(name: "idx_email", section: .indexes, table: "users")
        #expect(subject.title == "idx_email")
        #expect(subject.subtitle == String(format: String(localized: "Index of %@"), "users"))
    }

    @Test("Foreign keys and check constraints say what they are")
    func otherDefinitionKinds() {
        let foreignKey = InspectorSubject.definition(name: "fk_user", section: .foreignKeys, table: "orders")
        #expect(foreignKey.subtitle == String(format: String(localized: "Foreign Key of %@"), "orders"))
        let check = InspectorSubject.definition(name: "positive_total", section: .checkConstraints, table: "orders")
        #expect(check.subtitle == String(format: String(localized: "Check Constraint of %@"), "orders"))
    }

    @Test("A definition with no name yet reads as new")
    func unnamedDefinitionIsNew() {
        #expect(InspectorSubject.definition(name: "", section: .columns, table: "t").title == String(localized: "New Column"))
        #expect(InspectorSubject.definition(name: "", section: .indexes, table: "t").title == String(localized: "New Index"))
    }

    @Test("A definition with no known table still names its kind")
    func definitionWithoutTable() {
        let subject = InspectorSubject.definition(name: "user_id", section: .foreignKeys, table: nil)
        #expect(subject.title == "user_id")
        #expect(subject.subtitle == String(localized: "Foreign Key"))
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
