//
//  ExportDatabaseItemMergeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ExportDatabaseItemMergeTests {
    private func pendingSchema(tablesSelected: [Bool], selectsLoadedObjects: Bool = false) -> ExportDatabaseItem {
        let tables = tablesSelected.enumerated().map { index, isSelected in
            ExportObjectItem(name: "t\(index)", databaseName: "sales", kind: .table, isSelected: isSelected)
        }
        var item = ExportDatabaseItem(
            name: "sales",
            objects: tables,
            isExpanded: false,
            unloadedKinds: [.routine, .sequence]
        )
        item.isLoadingObjects = true
        item.selectsLoadedObjects = selectsLoadedObjects
        return item
    }

    private let arrivals = [
        ExportObjectItem(name: "refresh_totals", databaseName: "sales", kind: .routine),
        ExportObjectItem(name: "order_seq", databaseName: "sales", kind: .sequence),
    ]

    @Test("Arrivals stay unselected when the schema was only expanded")
    func expandedSchemaArrivalsStayUnselected() {
        let merged = pendingSchema(tablesSelected: [true, true]).mergingLoadedObjects(arrivals)

        #expect(merged.objects.filter { $0.kind != .table }.allSatisfy { !$0.isSelected })
        #expect(merged.unloadedKinds.isEmpty)
        #expect(!merged.isLoadingObjects)
    }

    @Test("Arrivals are selected when the schema was ticked whole and nothing was unticked since")
    func tickedSchemaSelectsArrivals() {
        let merged = pendingSchema(tablesSelected: [true, true], selectsLoadedObjects: true)
            .mergingLoadedObjects(arrivals)

        #expect(merged.objects.count == 4)
        #expect(merged.objects.allSatisfy { $0.isSelected })
        #expect(!merged.selectsLoadedObjects)
    }

    @Test("Arrivals stay unselected once something in the ticked schema was unticked")
    func untickedTableKeepsArrivalsUnselected() {
        let merged = pendingSchema(tablesSelected: [true, false], selectsLoadedObjects: true)
            .mergingLoadedObjects(arrivals)

        #expect(merged.objects.filter { $0.kind != .table }.allSatisfy { !$0.isSelected })
    }

    @Test("A ticked schema with no tables selects everything that arrives")
    func tickedTableLessSchemaSelectsArrivals() {
        let merged = pendingSchema(tablesSelected: [], selectsLoadedObjects: true).mergingLoadedObjects(arrivals)

        #expect(merged.objects.map(\.name) == ["refresh_totals", "order_seq"])
        #expect(merged.objects.allSatisfy { $0.isSelected })
    }

    @Test("An arrival restored as selected stays selected")
    func restoredArrivalStaysSelected() {
        var restored = arrivals
        restored[0].isSelected = true

        let merged = pendingSchema(tablesSelected: [false]).mergingLoadedObjects(restored)

        #expect(merged.objects.first { $0.name == "refresh_totals" }?.isSelected == true)
        #expect(merged.objects.first { $0.name == "order_seq" }?.isSelected == false)
    }

    @Test("An arrival of a kind the schema had already read is not added twice")
    func arrivalOfAReadKindIsIgnored() {
        let duplicate = ExportObjectItem(name: "t0", databaseName: "sales", kind: .table)

        let merged = pendingSchema(tablesSelected: [false]).mergingLoadedObjects([duplicate])

        #expect(merged.objects.count == 1)
    }

    @Test("A reload keeps each container's identity by name")
    func reloadAdoptsIdentitiesByName() {
        let prior = [
            ExportDatabaseItem(name: "public", objects: []),
            ExportDatabaseItem(name: "sales", objects: []),
        ]
        let reloaded = [
            ExportDatabaseItem(name: "sales", objects: [], unloadedKinds: [.routine]),
            ExportDatabaseItem(name: "archive", objects: []),
        ]

        let adopted = reloaded.adoptingIdentities(of: prior)

        #expect(adopted[0].id == prior[1].id)
        #expect(adopted[0].unloadedKinds == [.routine])
        #expect(adopted[1].id == reloaded[1].id)
    }

    @Test("A saved selection naming a kind its schema has not read yet still counts as present")
    func unreadProfileEntriesCountAsPresent() {
        let items = [pendingSchema(tablesSelected: [false])]
        let profile = ExportProfile(name: "Nightly", formatId: "sql", entries: [
            ExportProfile.Entry(container: "sales", name: "t0", kind: .table, optionValues: [], rowScope: .unrestricted),
            ExportProfile.Entry(
                container: "sales", name: "refresh_totals", kind: .routine, optionValues: [], rowScope: .unrestricted
            ),
            ExportProfile.Entry(container: "sales", name: "gone", kind: .table, optionValues: [], rowScope: .unrestricted),
        ])

        #expect(ExportProfileStorage.matchCount(profile, in: items) == 1)
        #expect(items.presentEntryCount(of: profile) == 2)
    }

    @Test("A narrower format drops unread kinds it cannot write, and a container left with nothing")
    func narrowingDropsUnreadKinds() {
        let tableLess = ExportDatabaseItem(name: "functions_only", objects: [], unloadedKinds: [.routine])

        let narrowed = [pendingSchema(tablesSelected: [true]), tableLess].narrowed(to: [.table, .view])

        #expect(narrowed.map(\.name) == ["sales"])
        #expect(narrowed.first?.unloadedKinds.isEmpty == true)
    }

    @Test("A container with unread kinds ends with a pending row that keeps it expandable")
    func pendingRowFollowsTheObjects() throws {
        let roots = ExportOutlineTreeBuilder.build(from: [pendingSchema(tablesSelected: [false, false])])
        let children = try #require(roots.first?.children)

        #expect(children.count == 3)
        guard let last = children.last, case .pending = last.kind else {
            Issue.record("expected the pending row last")
            return
        }
        let empty = ExportDatabaseItem(name: "functions_only", objects: [], unloadedKinds: [.routine])
        #expect(ExportOutlineTreeBuilder.build(from: [empty]).first?.isLeaf == false)
    }

    @Test("Reading a container's unread kinds changes the tree's shape")
    func mergeChangesTheShapeFingerprint() {
        let pending = pendingSchema(tablesSelected: [false])
        var read = pending
        read.unloadedKinds = []

        #expect(ExportOutlineTreeBuilder.shapeFingerprint(of: [pending])
            != ExportOutlineTreeBuilder.shapeFingerprint(of: [read]))
    }

    @Test("A whole-container preselection selects everything in the schemas it covers")
    func containerPreselectionSelectsWholeSchemas() {
        let database = ExportPreselection.containers([.database("app")])
        let schema = ExportPreselection.containers([.schema(database: "app", schema: "sales")])
        let tables = ExportPreselection.tables(names: ["orders"], scope: .schema(database: "app", schema: "sales"))

        #expect(database.selectsAllObjects(in: .schema(database: "app", schema: "archive")))
        #expect(schema.selectsAllObjects(in: .schema(database: "app", schema: "sales")))
        #expect(!schema.selectsAllObjects(in: .schema(database: "app", schema: "archive")))
        #expect(!tables.selectsAllObjects(in: .schema(database: "app", schema: "sales")))
    }
}
