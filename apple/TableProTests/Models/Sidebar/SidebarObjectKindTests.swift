//
//  SidebarObjectKindTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

struct SidebarObjectKindTests {
    private let everyKind: [SidebarObjectKind: Int] = [
        .table: 2, .view: 1, .materializedView: 1, .foreignTable: 1,
        .procedure: 1, .function: 1, .trigger: 1, .type: 1,
    ]

    /// The bug: a driver can return materialized views, foreign tables, procedures or functions that
    /// its plugin never declared a capability for, and the flat list used to drop them with no
    /// section, no status row and no error.
    @Test("A kind with items renders whatever its plugin declared")
    func itemsAlwaysRender() {
        #expect(
            SidebarObjectKind.visible(itemCounts: everyKind)
                == [.table, .view, .materializedView, .foreignTable, .procedure, .function, .trigger, .type]
        )
    }

    /// The report: a PostgreSQL schema with tables, views and functions, and no procedures, triggers
    /// or types, listed a Procedures, a Triggers and a Types section with nothing in them.
    @Test("Only kinds holding objects get a section")
    func emptyKindsAreOmitted() {
        let counts: [SidebarObjectKind: Int] = [.table: 3, .view: 2, .function: 2]
        #expect(SidebarObjectKind.visible(itemCounts: counts) == [.table, .view, .function])
    }

    @Test("A schema without tables gets no Tables section")
    func emptyTablesSectionIsOmitted() {
        #expect(SidebarObjectKind.visible(itemCounts: [.view: 1]) == [.view])
    }

    @Test("Nothing at all lists no section")
    func noContents() {
        #expect(SidebarObjectKind.visible(itemCounts: [:]).isEmpty)
    }

    /// The flat root supplies a count for every kind, so a zero has to read the same as a key that
    /// was never there.
    @Test("A kind counted as zero reads the same as a kind with no count at all")
    func explicitZeroCounts() {
        let counted: [SidebarObjectKind: Int] = [
            .table: 0, .view: 0, .materializedView: 0, .foreignTable: 0,
            .procedure: 0, .function: 1, .trigger: 0, .type: 0,
        ]
        #expect(SidebarObjectKind.visible(itemCounts: counted) == [.function])
    }

    /// A table kind whose objects are all in folders, and a kind whose fetch failed, have a reason to
    /// keep a section with no rows: the drop target that takes a table back out, and the error.
    @Test("A kept kind gets a section without objects, in declaration order")
    func keptKindShowsWithoutItems() {
        let visible = SidebarObjectKind.visible(itemCounts: [.function: 1], keeping: [.trigger, .table])
        #expect(visible == [.table, .function, .trigger])
    }

    @Test("Keeping a kind never hides one with objects")
    func keepingOnlyAdds() {
        let counts: [SidebarObjectKind: Int] = [.procedure: 2, .trigger: 1]
        #expect(SidebarObjectKind.visible(itemCounts: counts, keeping: [.view]) == [.view, .procedure, .trigger])
    }

    @Test("Every kind belongs to exactly one category")
    func categoriesPartitionTheKinds() {
        #expect(SidebarObjectKind.allCases.filter { $0.category == .routine } == [.procedure, .function])
        #expect(SidebarObjectKind.allCases.filter { $0.category == .trigger } == [.trigger])
        #expect(SidebarObjectKind.allCases.filter { $0.category == .type } == [.type])
        #expect(
            SidebarObjectKind.allCases.filter { $0.category == .table }
                == [.table, .view, .materializedView, .foreignTable]
        )
    }
}
