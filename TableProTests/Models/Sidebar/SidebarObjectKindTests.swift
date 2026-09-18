//
//  SidebarObjectKindTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("SidebarObjectKind visibility")
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
        for includingEmptyTables in [true, false] {
            let visible = SidebarObjectKind.visible(
                itemCounts: everyKind,
                includingEmptyTables: includingEmptyTables
            )
            #expect(
                visible == [.table, .view, .materializedView, .foreignTable, .procedure, .function, .trigger, .type]
            )
        }
    }

    @Test("Both sidebar layouts list the same object kinds for the same contents")
    func layoutsAgreeOnNonTableKinds() {
        let counts: [SidebarObjectKind: Int] = [.materializedView: 3, .foreignTable: 1, .function: 2]

        let flat = SidebarObjectKind.visible(itemCounts: counts, includingEmptyTables: true)
        let container = SidebarObjectKind.visible(itemCounts: counts, includingEmptyTables: false)

        #expect(flat.filter { $0 != .table } == container.filter { $0 != .table })
        #expect(container == [.materializedView, .foreignTable, .function])
    }

    /// The flat root's sections are chrome that exists before their contents do, so Tables stays.
    /// A tree container says the same thing with its own status row and lists no empty group.
    @Test("Only the flat root keeps an empty Tables section")
    func emptyTablesSectionIsFlatOnly() {
        let counts: [SidebarObjectKind: Int] = [.view: 1]

        #expect(SidebarObjectKind.visible(itemCounts: counts, includingEmptyTables: true) == [.table, .view])
        #expect(SidebarObjectKind.visible(itemCounts: counts, includingEmptyTables: false) == [.view])
    }

    @Test("An empty kind other than tables never renders")
    func emptyKindsAreOmitted() {
        let counts: [SidebarObjectKind: Int] = [.table: 4]

        #expect(SidebarObjectKind.visible(itemCounts: counts, includingEmptyTables: true) == [.table])
        #expect(SidebarObjectKind.visible(itemCounts: counts, includingEmptyTables: false) == [.table])
    }

    @Test("Nothing at all leaves the flat root with Tables and a container with no groups")
    func noContents() {
        #expect(SidebarObjectKind.visible(itemCounts: [:], includingEmptyTables: true) == [.table])
        #expect(SidebarObjectKind.visible(itemCounts: [:], includingEmptyTables: false).isEmpty)
    }

    /// The flat root supplies a count for every kind, so a zero has to read the same as a key that
    /// was never there.
    @Test("A kind counted as zero reads the same as a kind with no count at all")
    func explicitZeroCounts() {
        let counted: [SidebarObjectKind: Int] = [
            .table: 0, .view: 0, .materializedView: 0, .foreignTable: 0,
            .procedure: 0, .function: 1, .trigger: 0,
        ]

        for includingEmptyTables in [true, false] {
            #expect(
                SidebarObjectKind.visible(itemCounts: counted, includingEmptyTables: includingEmptyTables)
                    == SidebarObjectKind.visible(
                        itemCounts: [.function: 1], includingEmptyTables: includingEmptyTables
                    )
            )
        }
        #expect(SidebarObjectKind.visible(itemCounts: counted, includingEmptyTables: false) == [.function])
    }

    /// The declared set only ever adds a section. A kind whose driver returned rows is listed
    /// whatever the flag says, which is the invariant this type's own doc comment records.
    @Test("A declared kind with no items still gets a section")
    func declaredKindShowsEmptySection() {
        let counts: [SidebarObjectKind: Int] = [.table: 3]
        let visible = SidebarObjectKind.visible(
            itemCounts: counts,
            declaredKinds: [.procedure, .function, .trigger],
            includingEmptyTables: false
        )
        #expect(visible == [.table, .procedure, .function, .trigger])
    }

    @Test("An undeclared kind that returned rows is never hidden")
    func undeclaredKindWithItemsStillRenders() {
        let counts: [SidebarObjectKind: Int] = [.procedure: 2, .trigger: 1]
        let visible = SidebarObjectKind.visible(
            itemCounts: counts,
            declaredKinds: [],
            includingEmptyTables: false
        )
        #expect(visible == [.procedure, .trigger])
    }

    @Test("Declaring nothing leaves the old behaviour unchanged")
    func emptyDeclarationMatchesCountOnlyRule() {
        let counts: [SidebarObjectKind: Int] = [.view: 1, .function: 2]
        for includingEmptyTables in [true, false] {
            #expect(
                SidebarObjectKind.visible(
                    itemCounts: counts, declaredKinds: [], includingEmptyTables: includingEmptyTables
                )
                    == SidebarObjectKind.visible(
                        itemCounts: counts, includingEmptyTables: includingEmptyTables
                    )
            )
        }
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
