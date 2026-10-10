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

        init() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ExportObjectColumn"))
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.allowsMultipleSelection = true
            scrollView.documentView = outlineView
            let view = ExportObjectTreeView(
                databaseItems: Binding(get: { self.items }, set: { self.items = $0 }),
                formatId: "sql",
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
}
