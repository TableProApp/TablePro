//
//  ObjectListingKindsTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct ObjectListingKindsTests {
    @Test("Tables lead, then the kinds the container holds, in the sidebar's order")
    func kindsFollowTheSidebar() {
        let kinds = ObjectListingKinds.available(
            itemCounts: [.view: 2, .function: 3, .sequence: 0, .trigger: 1],
            declared: [.procedure, .function, .trigger],
            current: .table
        )

        #expect(kinds == [.table, .view, .function, .trigger])
    }

    @Test("A routine, trigger or type kind the engine does not fetch is left out even with rows")
    func undeclaredSideKindsAreLeftOut() {
        let kinds = ObjectListingKinds.available(itemCounts: [.type: 4, .view: 1], declared: [], current: .table)

        #expect(kinds == [.table, .view])
    }

    @Test("The tab's own kind stays offered while the container holds none of it")
    func currentKindStays() {
        let kinds = ObjectListingKinds.available(itemCounts: [:], declared: [.procedure], current: .procedure)

        #expect(kinds == [.table, .procedure])
    }

    @Test("A routine, trigger or type kind the engine stopped fetching falls back to Tables; a relation kind never does")
    func undeclaredKindFallsBack() {
        #expect(ObjectListingKinds.effective(.function, declared: []) == .table)
        #expect(ObjectListingKinds.effective(.trigger, declared: [.procedure]) == .table)
        #expect(ObjectListingKinds.effective(.function, declared: [.function]) == .function)
        #expect(ObjectListingKinds.effective(.view, declared: []) == .view)
    }

    @Test("Counts sort tables by their kind and routines by theirs")
    func itemCountsSortObjects() {
        let counts = ObjectListingKinds.itemCounts(
            tables: [
                TableInfo(name: "orders", type: .table, rowCount: nil),
                TableInfo(name: "events", type: .partitionedTable, rowCount: nil),
                TableInfo(name: "recent", type: .view, rowCount: nil),
            ],
            routines: [
                RoutineInfo(name: "touch", kind: .function),
                RoutineInfo(name: "archive", kind: .procedure),
                RoutineInfo(name: "total", kind: .function),
            ],
            triggers: [TriggerInfo(name: "audit", timing: "AFTER", event: "INSERT", statement: "")],
            types: []
        )

        #expect(counts[.table] == 2)
        #expect(counts[.view] == 1)
        #expect(counts[.function] == 2)
        #expect(counts[.procedure] == 1)
        #expect(counts[.trigger] == 1)
        #expect(counts[.type] == 0)
    }

    @Test("Each kind names itself when it cannot be listed and when it has nothing")
    func kindsNameTheirStates() {
        #expect(SidebarObjectKind.table.listingFailureTitle == String(localized: "Can't List Tables"))
        #expect(SidebarObjectKind.view.listingFailureTitle == String(localized: "Can't List Views"))
        #expect(SidebarObjectKind.table.listingEmptyTitle == String(localized: "No Tables"))
        #expect(SidebarObjectKind.trigger.listingEmptyTitle == String(localized: "No Triggers"))
    }
}
