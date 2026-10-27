//
//  ExportObjectTreeCoordinatorTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ExportObjectTreeCoordinatorTests {
    @MainActor
    private final class Harness {
        var items: [ExportDatabaseItem] = []
        var requests: [UUID] = []
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let outlineView = NSOutlineView()
        var coordinator: ExportObjectTreeCoordinator?

        init(options: ExportOptionLayout = .none) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ExportObjectColumn"))
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.allowsMultipleSelection = true
            scrollView.documentView = outlineView
            let view = ExportObjectTreeView(
                databaseItems: Binding(get: { self.items }, set: { self.items = $0 }),
                formatId: "sql",
                options: options,
                databaseType: .postgresql,
                loadColumns: { _ in [] },
                onNeedsObjects: { self.requests.append($0) }
            )
            let coordinator = ExportObjectTreeCoordinator(owner: view)
            outlineView.dataSource = coordinator
            outlineView.delegate = coordinator
            coordinator.attach(outlineView: outlineView)
            self.coordinator = coordinator
        }

        func apply(_ databases: [ExportDatabaseItem]) {
            items = databases
            coordinator?.apply(databases: databases, formatId: "sql")
        }

        func row(of identity: String) -> Int? {
            (0 ..< outlineView.numberOfRows).first { row in
                (outlineView.item(atRow: row) as? ExportOutlineNode)?.identity == identity
            }
        }

        func node(of identity: String) -> ExportOutlineNode? {
            row(of: identity).flatMap { outlineView.item(atRow: $0) as? ExportOutlineNode }
        }

        func pressSpace(on node: ExportOutlineNode) {
            outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: node)), byExtendingSelection: false)
            coordinator?.toggleSelectedRows()
        }
    }

    private static func table(_ name: String, in schema: String) -> ExportObjectItem {
        ExportObjectItem(name: name, databaseName: schema, kind: .table)
    }

    private static func realTree() -> (publicSchema: ExportDatabaseItem, sales: ExportDatabaseItem) {
        let publicSchema = ExportDatabaseItem(name: "public", objects: [table("users", in: "public")], isExpanded: true)
        let sales = ExportDatabaseItem(
            name: "sales",
            objects: [table("orders", in: "sales")],
            isExpanded: false,
            unloadedKinds: [.routine]
        )
        return (publicSchema, sales)
    }

    @Test("The tree that replaces the sidebar preview opens only what the builder opened")
    func replacingTreeKeepsCollapsedSchemasShut() throws {
        let harness = Harness()
        harness.apply([ExportDatabaseItem(name: "app", objects: [Self.table("users", in: "")], isExpanded: true)])
        let (publicSchema, sales) = Self.realTree()

        harness.apply([publicSchema, sales])

        let publicNode = try #require(harness.node(of: "db:\(publicSchema.id.uuidString)"))
        let salesNode = try #require(harness.node(of: "db:\(sales.id.uuidString)"))
        #expect(harness.outlineView.isItemExpanded(publicNode))
        #expect(!harness.outlineView.isItemExpanded(salesNode))
        #expect(harness.requests.isEmpty)
        _ = harness.scrollView
    }

    @Test("Expanding a schema with unread kinds asks for them")
    func expandingAPendingSchemaAsksForItsObjects() throws {
        let harness = Harness()
        let (publicSchema, sales) = Self.realTree()
        harness.apply([publicSchema, sales])
        let salesNode = try #require(harness.node(of: "db:\(sales.id.uuidString)"))

        harness.coordinator?.outlineViewItemDidExpand(Notification(
            name: NSOutlineView.itemDidExpandNotification,
            object: harness.outlineView,
            userInfo: ["NSObject": salesNode]
        ))

        #expect(harness.requests.contains(sales.id))
        #expect(!harness.requests.contains(publicSchema.id))
    }

    @Test("Ticking a schema with unread kinds asks for them and marks them to arrive selected")
    func tickingAPendingSchemaAsksAndSelects() throws {
        let harness = Harness()
        let (publicSchema, sales) = Self.realTree()
        harness.apply([publicSchema, sales])
        let salesRow = try #require(harness.row(of: "db:\(sales.id.uuidString)"))
        harness.outlineView.selectRowIndexes(IndexSet(integer: salesRow), byExtendingSelection: false)

        harness.coordinator?.toggleSelectedRows()

        let updated = try #require(harness.items.first { $0.id == sales.id })
        #expect(harness.requests == [sales.id])
        #expect(updated.selectsLoadedObjects)
        #expect(updated.objects.allSatisfy { $0.isSelected })
    }

    @Test("Unticking a schema with unread kinds asks for nothing")
    func untickingAPendingSchemaAsksForNothing() throws {
        let harness = Harness()
        let tree = Self.realTree()
        var sales = tree.sales
        sales.objects[0].isSelected = true
        harness.apply([tree.publicSchema, sales])
        let salesRow = try #require(harness.row(of: "db:\(sales.id.uuidString)"))
        harness.outlineView.selectRowIndexes(IndexSet(integer: salesRow), byExtendingSelection: false)

        harness.coordinator?.toggleSelectedRows()

        let updated = try #require(harness.items.first { $0.id == sales.id })
        #expect(harness.requests.isEmpty)
        #expect(!updated.selectsLoadedObjects)
        #expect(updated.objects.allSatisfy { !$0.isSelected })
    }

    @Test("The loading row cannot be selected")
    func pendingRowIsNotSelectable() throws {
        let harness = Harness()
        let (publicSchema, sales) = Self.realTree()
        harness.apply([publicSchema, sales])
        let pendingNode = ExportOutlineNode(kind: .pending(databaseID: sales.id))

        let selectable = harness.coordinator?.outlineView(harness.outlineView, shouldSelectItem: pendingNode)

        #expect(selectable == false)
    }

    private static func sqlTree() -> ExportDatabaseItem {
        ExportDatabaseItem(
            name: "app",
            objects: [
                ExportObjectItem(name: "users", kind: .table, isSelected: true, optionValues: [true, true, true]),
                ExportObjectItem(name: "orders", kind: .table, isSelected: true, optionValues: [true, true, true])
            ],
            isExpanded: true
        )
    }

    @Test("A database's Data checkbox turns Data off for every table under it and keeps them selected")
    func databaseOptionCheckboxSetsTheColumn() throws {
        let harness = Harness(options: .sqlForTests)
        let database = Self.sqlTree()
        harness.apply([database])
        let node = try #require(harness.node(of: "db:\(database.id.uuidString)"))

        harness.coordinator?.toggleOption(2, under: node)

        let updated = try #require(harness.items.first)
        #expect(updated.objects.allSatisfy { $0.optionValues == [true, true, false] && $0.isSelected })
    }

    @Test("A mixed column turns on for every object on the first click")
    func mixedColumnTurnsOn() throws {
        let harness = Harness(options: .sqlForTests)
        var database = Self.sqlTree()
        database.objects[0].optionValues = [true, false, true]
        harness.apply([database])
        let node = try #require(harness.node(of: "db:\(database.id.uuidString)"))

        harness.coordinator?.toggleOption(1, under: node)

        let updated = try #require(harness.items.first)
        #expect(updated.objects.allSatisfy { $0.optionValues == [true, true, true] })
    }

    @Test("A column set on a schema with unread kinds is kept for them")
    func columnOnAPendingSchemaIsKeptForArrivals() throws {
        let harness = Harness(options: .sqlForTests)
        let (publicSchema, sales) = Self.realTree()
        harness.apply([publicSchema, sales])
        let node = try #require(harness.node(of: "db:\(sales.id.uuidString)"))

        harness.coordinator?.toggleOption(1, under: node)

        let updated = try #require(harness.items.first { $0.id == sales.id })
        #expect(updated.arrivingOptionValues == [1: false])
        #expect(harness.requests.isEmpty)
    }

    @Test("Space over a database and its tables unticks everything once instead of flipping it back")
    func spaceOverNestedRowsActsOnce() throws {
        let harness = Harness(options: .sqlForTests)
        let database = Self.sqlTree()
        harness.apply([database])
        harness.outlineView.selectRowIndexes(IndexSet(integersIn: 0 ..< harness.outlineView.numberOfRows), byExtendingSelection: false)

        harness.coordinator?.toggleSelectedRows()

        let updated = try #require(harness.items.first)
        #expect(updated.objects.allSatisfy { !$0.isSelected })
    }

    @Test("Each option column gets a real table column with a heading, and a format without columns has none")
    func optionColumnsAreTableColumns() {
        let withColumns = Harness(options: .sqlForTests)
        withColumns.apply([Self.sqlTree()])
        #expect(withColumns.outlineView.tableColumns.map(\.title).dropFirst() == ["Structure", "Drop", "Data"])
        #expect(withColumns.outlineView.headerView != nil)

        let without = Harness()
        without.apply([Self.sqlTree()])
        #expect(without.outlineView.tableColumns.count == 1)
        #expect(without.outlineView.headerView == nil)
    }

    @Test("A group whose kind has no Data column leaves that cell empty")
    func unsupportedColumnHasNoContainerState() throws {
        let harness = Harness(options: .sqlForTests)
        let database = ExportDatabaseItem(name: "app", objects: [
            ExportObjectItem(name: "users", kind: .table, isSelected: true, optionValues: [true, true, true]),
            ExportObjectItem(name: "recalc", kind: .routine, isSelected: true, optionValues: [true, true, false])
        ])
        harness.apply([database])
        let routines = try #require(harness.node(of: "group:\(database.id.uuidString):\(PluginExportObjectKind.routine.rawValue)"))

        #expect(harness.coordinator?.optionState(ofColumn: 2, under: routines) == nil)
        #expect(harness.coordinator?.optionState(ofColumn: 1, under: routines) == .on)
    }

    @Test("Clicking an object's checkbox only includes or excludes it, whatever its options")
    func objectCheckboxIsSelectionOnly() throws {
        let harness = Harness(options: .sqlForTests)
        var database = Self.sqlTree()
        database.objects[0].optionValues = [true, false, false]
        harness.apply([database])

        harness.coordinator?.toggleObject(databaseID: database.id, objectID: database.objects[0].id)

        let updated = try #require(harness.items.first?.objects.first)
        #expect(!updated.isSelected)
        #expect(updated.optionValues == [true, false, false])
    }

    /// Without it, Structure and Drop off before the tick handed views and routines the format's
    /// defaults back, and a data-only export wrote their DDL.
    @Test("Turning columns off before or after ticking the database gives the same export")
    func clickOrderDoesNotChangeTheExport() throws {
        func tree() -> ExportDatabaseItem {
            ExportDatabaseItem(name: "app", objects: [
                ExportObjectItem(name: "users", kind: .table, optionValues: [true, true, true]),
                ExportObjectItem(name: "active_users", kind: .view, optionValues: [true, true, false])
            ])
        }
        func export(_ steps: (Harness, ExportObjectTreeCoordinator, ExportOutlineNode) -> Void) throws -> [String] {
            let harness = Harness(options: .sqlForTests)
            let database = tree()
            harness.apply([database])
            let node = try #require(harness.node(of: "db:\(database.id.uuidString)"))
            let coordinator = try #require(harness.coordinator)
            steps(harness, coordinator, node)
            let objects = try #require(harness.items.first).objects
            return objects.filter { $0.isSelected }.map { "\($0.name)=\($0.optionValues)" }
        }

        let tickFirst = try export { harness, coordinator, node in
            harness.pressSpace(on: node)
            coordinator.toggleOption(0, under: node)
            coordinator.toggleOption(1, under: node)
        }
        let tickLast = try export { harness, coordinator, node in
            coordinator.toggleOption(0, under: node)
            coordinator.toggleOption(1, under: node)
            harness.pressSpace(on: node)
        }

        #expect(tickFirst == ["users=[false, false, true]"])
        #expect(tickLast == tickFirst)
    }

    @Test("A group whose every option is off cannot be ticked, so its objects stay out")
    func allOffGroupStaysOut() throws {
        let harness = Harness(options: .sqlForTests)
        let database = ExportDatabaseItem(name: "app", objects: [
            ExportObjectItem(name: "users", kind: .table, isSelected: true, optionValues: [true, true, true]),
            ExportObjectItem(name: "recalc", kind: .routine, optionValues: [true, true, false])
        ])
        harness.apply([database])
        let identity = "group:\(database.id.uuidString):\(PluginExportObjectKind.routine.rawValue)"
        let routines = try #require(harness.node(of: identity))
        let coordinator = try #require(harness.coordinator)
        coordinator.toggleOption(0, under: routines)
        coordinator.toggleOption(1, under: routines)

        harness.pressSpace(on: try #require(harness.node(of: identity)))

        let routine = try #require(harness.items.first?.objects.first { $0.kind == .routine })
        #expect(!routine.isSelected)
        #expect(!coordinator.selectionIsEnabled(for: routines))
    }

    @Test("A group that cannot be ticked does not keep Space from unticking the rows selected with it")
    func spaceIgnoresAnAllOffGroup() throws {
        let harness = Harness(options: .sqlForTests)
        let database = ExportDatabaseItem(name: "app", objects: [
            ExportObjectItem(name: "users", kind: .table, isSelected: true, optionValues: [true, true, true]),
            ExportObjectItem(name: "recalc", kind: .routine, optionValues: [false, false, false])
        ])
        harness.apply([database])
        let tables = try #require(harness.row(of: "group:\(database.id.uuidString):\(PluginExportObjectKind.table.rawValue)"))
        let routines = try #require(harness.row(of: "group:\(database.id.uuidString):\(PluginExportObjectKind.routine.rawValue)"))
        harness.outlineView.selectRowIndexes(IndexSet([tables, routines]), byExtendingSelection: false)

        harness.coordinator?.toggleSelectedRows()

        let users = try #require(harness.items.first?.objects.first { $0.name == "users" })
        #expect(!users.isSelected)
    }

    @Test("Space ticks an object whose options are all off, as a click does, back to the defaults")
    func spaceTicksAnAllOffObject() throws {
        let harness = Harness(options: .sqlForTests)
        var database = Self.sqlTree()
        database.objects[0].isSelected = false
        database.objects[0].optionValues = [false, false, false]
        harness.apply([database])
        let identity = "obj:\(database.id.uuidString):\(database.objects[0].id.uuidString)"

        harness.pressSpace(on: try #require(harness.node(of: identity)))

        let users = try #require(harness.items.first?.objects.first)
        #expect(users.isSelected)
        #expect(users.optionValues == [true, true, true])
    }

    @Test("Space on a group that cannot be ticked and a row under it still ticks the row")
    func spaceReachesARowUnderADisabledGroup() throws {
        let harness = Harness(options: .sqlForTests)
        let database = ExportDatabaseItem(name: "app", objects: [
            ExportObjectItem(name: "users", kind: .table, isSelected: true, optionValues: [true, true, true]),
            ExportObjectItem(name: "recalc", kind: .routine, optionValues: [false, false, false])
        ])
        harness.apply([database])
        let group = try #require(harness.row(of: "group:\(database.id.uuidString):\(PluginExportObjectKind.routine.rawValue)"))
        let routine = try #require(harness.row(of: "obj:\(database.id.uuidString):\(database.objects[1].id.uuidString)"))
        harness.outlineView.selectRowIndexes(IndexSet([group, routine]), byExtendingSelection: false)

        harness.coordinator?.toggleSelectedRows()

        let recalc = try #require(harness.items.first?.objects.first { $0.name == "recalc" })
        #expect(recalc.isSelected)
        #expect(recalc.optionValues == [true, true, false])
    }
}
