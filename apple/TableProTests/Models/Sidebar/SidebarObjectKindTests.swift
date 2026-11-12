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
        #expect(SidebarObjectKind.builtIn.filter { $0.category == .routine } == [.procedure, .function])
        #expect(SidebarObjectKind.builtIn.filter { $0.category == .trigger } == [.trigger])
        #expect(SidebarObjectKind.builtIn.filter { $0.category == .type } == [.type])
        #expect(
            SidebarObjectKind.builtIn.filter { $0.category == .table }
                == [.table, .view, .materializedView, .foreignTable, .sequence]
        )
        #expect(!SidebarObjectKind.builtIn.contains { $0.category == .server })
        #expect(SidebarObjectKind.server(events).category == .server)
    }

    private let events = SidebarServerObjectKind(
        id: "event", displayName: "Event", pluralDisplayName: "Events", iconName: "calendar.badge.clock", scope: .container
    )
    private let extensions = SidebarServerObjectKind(
        id: "extension", displayName: "Extension", pluralDisplayName: "Extensions", iconName: "puzzlepiece.extension",
        scope: .database
    )

    /// UserDefaults keys, the tree expansion JSON and node ids all spell these, so they never move.
    @Test("A built-in kind persists under the name it shipped with")
    func builtInPersistenceNamesAreShipped() {
        #expect(SidebarObjectKind.builtIn.map { $0.persistenceName } == [
            "table", "view", "materializedView", "foreignTable", "sequence", "procedure", "function", "trigger", "type",
        ])
        for kind in SidebarObjectKind.builtIn {
            #expect(SidebarObjectKind(persistenceName: kind.persistenceName) == kind)
        }
    }

    @Test("A declared kind persists by its id and decodes without the driver that declared it")
    func declaredKindRoundTripsByIdAlone() {
        let kind = SidebarObjectKind.server(events)
        #expect(kind.persistenceName == "server.event")
        let decoded = SidebarObjectKind(persistenceName: "server.event")
        #expect(decoded == kind)
        #expect(decoded?.hashValue == kind.hashValue)
        #expect(decoded?.serverKind?.id == "event")
    }

    @Test("An unknown or empty name decodes to nothing")
    func unknownPersistenceNameIsSkipped() {
        #expect(SidebarObjectKind(persistenceName: "dictionary") == nil)
        #expect(SidebarObjectKind(persistenceName: "server.") == nil)
        #expect(SidebarObjectKind(persistenceName: "") == nil)
    }

    @Test("Declared kinds follow the built-ins, in the order the driver declared them")
    func declaredKindsFollowBuiltIns() {
        let ordered = SidebarObjectKind.ordered(declared: [events, extensions])
        #expect(Array(ordered.prefix(SidebarObjectKind.builtIn.count)) == SidebarObjectKind.builtIn)
        #expect(Array(ordered.suffix(2)) == [.server(events), .server(extensions)])
    }

    @Test("A declared kind is listed only for its rows or a kept failure, never for being declared")
    func declaredKindVisibility() {
        let counted: [SidebarObjectKind: Int] = [.trigger: 1, .server(SidebarServerObjectKind(id: "event")): 2]
        #expect(
            SidebarObjectKind.visible(itemCounts: counted, declared: [events, extensions])
                == [.trigger, .server(events)]
        )
        #expect(
            SidebarObjectKind.visible(itemCounts: [:], keeping: [.server(extensions)], declared: [events, extensions])
                == [.server(extensions)]
        )
        #expect(SidebarObjectKind.visible(itemCounts: counted).isEmpty == false)
        #expect(SidebarObjectKind.visible(itemCounts: counted) == [.trigger])
    }

    @Test("A declared kind reads its names and symbol from the driver's descriptor")
    func declaredKindDisplay() {
        let kind = SidebarObjectKind.server(extensions)
        #expect(kind.displayName == "Extension")
        #expect(kind.pluralDisplayName == "Extensions")
        #expect(kind.iconName == "puzzlepiece.extension")
        #expect(kind.title(tableEntityName: "Collections") == "Extensions")
        #expect(!kind.isExpandedByDefault)
    }
}
