//
//  ExportOptionColumnTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension ExportOptionLayout {
    static var sqlForTests: ExportOptionLayout {
        ExportOptionLayout(
            columns: [
                PluginExportOptionColumn(id: "structure", label: "Structure", width: 56),
                PluginExportOptionColumn(id: "drop", label: "Drop", width: 44),
                PluginExportOptionColumn(id: "data", label: "Data", width: 44)
            ],
            defaultValues: [true, true, true],
            readsRows: true
        ) { columnId, kind in
            switch columnId {
            case "data": return kind.carriesRows
            case "drop": return kind != .grant
            default: return true
            }
        }
    }
}

struct ExportOptionColumnTests {
    private let layout = ExportOptionLayout.sqlForTests

    private func table(_ name: String, selected: Bool = true, _ values: [Bool] = [true, true, true]) -> ExportObjectItem {
        ExportObjectItem(name: name, kind: .table, isSelected: selected, optionValues: values)
    }

    @Test("A column's values come from the objects whose kind has it")
    func valuesSkipUnsupportedKinds() {
        let objects = [
            table("users", [true, true, false]),
            ExportObjectItem(name: "recalc", kind: .routine, isSelected: true, optionValues: [true, true, false])
        ]
        #expect(layout.values(ofColumn: 2, in: objects) == [false])
        #expect(layout.values(ofColumn: 1, in: objects) == [true, true])
    }

    @Test("No object with the column gives no values, so the container leaves the slot blank")
    func noSupportingObjectGivesNoValues() {
        let routines = [ExportObjectItem(name: "recalc", kind: .routine, optionValues: [true, true, false])]
        #expect(layout.values(ofColumn: 2, in: routines).isEmpty)
    }

    @Test("Unread kinds count with the value they will arrive with")
    func unreadKindsCountWithTheirArrivingValue() {
        let objects = [table("users", [true, false, true])]
        #expect(layout.values(ofColumn: 1, in: objects, unloadedKinds: [.routine]) == [false, true])
        #expect(layout.values(ofColumn: 1, in: objects, unloadedKinds: [.routine], arriving: [1: false]) == [false, false])
        #expect(layout.values(ofColumn: 2, in: objects, unloadedKinds: [.routine]) == [true])
    }

    @Test("Turning a column off keeps the objects that still write something selected")
    func columnOffKeepsSelection() {
        let databases = [ExportDatabaseItem(name: "app", objects: [table("users"), table("orders")])]
        let ids = Set(databases[0].objects.map(\.id))

        let updated = databases.settingOption(2, to: false, objectIDs: ids)

        #expect(updated[0].objects.allSatisfy { $0.optionValues == [true, true, false] && $0.isSelected })
    }

    @Test("A selected object left with no option on is deselected")
    func lastOptionOffDeselects() {
        let databases = [ExportDatabaseItem(name: "app", objects: [table("users", [false, false, true])])]

        let updated = databases.settingOption(2, to: false, objectIDs: [databases[0].objects[0].id])

        #expect(updated[0].objects[0].optionValues == [false, false, false])
        #expect(!updated[0].objects[0].isSelected)
    }

    @Test("A column write never selects, and an unticked object keeps the value for when it is ticked")
    func columnWriteNeverSelects() {
        let databases = [ExportDatabaseItem(name: "app", objects: [table("users", selected: false)])]

        let updated = databases.settingOption(2, to: false, objectIDs: [databases[0].objects[0].id])

        #expect(!updated[0].objects[0].isSelected)
        #expect(updated[0].objects[0].optionValues == [true, true, false])
    }

    @Test("A column write reaches only the objects it names")
    func columnWriteReachesOnlyNamedObjects() {
        let databases = [ExportDatabaseItem(name: "app", objects: [table("users"), table("orders")])]

        let updated = databases.settingOption(2, to: false, objectIDs: [databases[0].objects[0].id])

        #expect(updated[0].objects[1].optionValues == [true, true, true])
    }

    @Test("A container with unread kinds keeps the value for them, and only that container")
    func arrivingValueIsKeptPerContainer() {
        let databases = [
            ExportDatabaseItem(name: "public", objects: [table("users")]),
            ExportDatabaseItem(name: "sales", objects: [table("orders")], unloadedKinds: [.routine])
        ]

        let updated = databases.settingOption(1, to: false, objectIDs: [], arrivingIn: databases[1].id)

        #expect(updated[0].arrivingOptionValues.isEmpty)
        #expect(updated[1].arrivingOptionValues == [1: false])
    }

    @Test("Arrivals take the container's values over the format's defaults, for the columns their kind has")
    func arrivalsTakeTheContainersValues() {
        let routine = ExportObjectItem(name: "recalc", kind: .routine, isSelected: true, optionValues: [true, true, false])
        let existing = table("users")
        let database = ExportDatabaseItem(name: "sales", objects: [existing, routine])

        let updated = database.applyingOptionValues([1: false, 2: true], toObjects: [routine.id], layout: layout)

        #expect(updated.objects[0].optionValues == [true, true, true])
        #expect(updated.objects[1].optionValues == [true, false, false])
        #expect(updated.objects[1].isSelected)
    }

    @Test("An arrival left with nothing to write arrives unselected")
    func arrivalWithNothingOnIsDeselected() {
        let routine = ExportObjectItem(name: "recalc", kind: .routine, isSelected: true, optionValues: [true, true, false])
        let database = ExportDatabaseItem(name: "sales", objects: [routine])

        let updated = database.applyingOptionValues([0: false, 1: false], toObjects: [routine.id], layout: layout)

        #expect(!updated.objects[0].isSelected)
    }

    @Test("The merge consumes the arriving values, a reload keeps them and a format change clears them")
    func arrivingValuesLifecycle() {
        var database = ExportDatabaseItem(name: "sales", objects: [table("orders")], unloadedKinds: [.routine])
        database.arrivingOptionValues = [1: false]

        #expect(database.withID(UUID()).arrivingOptionValues == [1: false])
        #expect(database.mergingLoadedObjects([]).arrivingOptionValues.isEmpty)
        #expect([database].resettingOptionValues(to: [true, true, true])[0].arrivingOptionValues.isEmpty)
    }

    @Test("Arrivals take the kept values after the format's defaults fill in their empty lists")
    func mergeAppliesKeptValuesAfterNormalizing() throws {
        let orders = table("orders")
        var database = ExportDatabaseItem(name: "sales", objects: [orders], unloadedKinds: [.routine, .view])
        database.selectsLoadedObjects = true
        database.arrivingOptionValues = [1: false]
        let loaded = [
            ExportObjectItem(name: "recalc", kind: .routine),
            ExportObjectItem(name: "active_orders", kind: .view)
        ]

        let merged = try #require(database.mergingLoadedObjects(loaded, layout: layout))

        #expect(merged.objects[0].optionValues == [true, true, true])
        #expect(merged.objects.dropFirst().allSatisfy { $0.optionValues == [true, false, false] && $0.isSelected })
        #expect(merged.arrivingOptionValues.isEmpty)
    }

    @Test("A tick that skipped an object writing nothing still brings the unread kinds in selected")
    func arrivalsSelectedPastAnAllOffObject() throws {
        var database = ExportDatabaseItem(
            name: "sales",
            objects: [table("orders"), ExportObjectItem(name: "v", kind: .view, optionValues: [false, false, false])],
            unloadedKinds: [.routine]
        )
        database.selectsLoadedObjects = true

        let merged = try #require(database.mergingLoadedObjects([ExportObjectItem(name: "recalc", kind: .routine)], layout: layout))

        #expect(merged.objects.first { $0.name == "recalc" }?.isSelected == true)
        #expect(merged.objects.first { $0.name == "v" }?.isSelected == false)
    }

    @Test("A read that finds nothing leaves no container")
    func mergeOfNothingIsNil() {
        let database = ExportDatabaseItem(name: "empty", objects: [], unloadedKinds: [.routine])
        #expect(database.mergingLoadedObjects([], layout: layout) == nil)
    }

    @Test("Narrowing records the kinds that are left, so widening again reads them back")
    func narrowThenWidenReloads() {
        let sqlKinds: Set<PluginExportObjectKind> = [.table, .view, .routine, .trigger]
        let csvKinds: Set<PluginExportObjectKind> = [.table, .view]

        let toCSV = ExportKindReconciliation.next(loadedKinds: sqlKinds, wanted: csvKinds)
        #expect(toCSV == .narrowed(loadedKinds: csvKinds))
        guard case .narrowed(let left) = toCSV else { return }
        #expect(ExportKindReconciliation.next(loadedKinds: left, wanted: sqlKinds) == .reload)
    }

    @Test("Nothing loaded yet means the load in flight decides the kinds")
    func reconcileBeforeTheFirstLoadDoesNothing() {
        #expect(ExportKindReconciliation.next(loadedKinds: [], wanted: [.table]) == .unchanged)
        #expect(ExportKindReconciliation.next(loadedKinds: [.table], wanted: [.table]) == .unchanged)
    }

    @Test("A profile's options survive being applied over a tree reset for its format")
    func profileKeepsItsOptions() {
        let users = table("users", selected: false)
        let profile = ExportProfile(name: "Schema only", formatId: "sql", entries: [
            ExportProfile.Entry(
                container: "app", name: "users", kind: .table,
                optionValues: [true, false, false], rowScope: .unrestricted
            )
        ])
        let reset = [ExportDatabaseItem(name: "app", objects: [users])].resettingOptionValues(to: layout.defaultValues)

        let applied = reset.applyingProfile(profile, layout: layout, databaseType: .postgresql)

        #expect(applied[0].objects[0].isSelected)
        #expect(applied[0].objects[0].optionValues == [true, false, false])
    }
}
