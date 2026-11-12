//
//  ObjectListingTableViewTests.swift
//  TableProTests
//

import AppKit
import Combine
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ObjectListingTableViewTests {
    private let defaults: EphemeralDefaults

    init() throws {
        defaults = try EphemeralDefaults()
    }

    private func makeModel() -> TableListingViewModel {
        TableListingViewModel(
            tabId: UUID(),
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            loader: TableListingLoader(databaseType: .mysql, slot: .database),
            refreshRequests: Empty().eraseToAnyPublisher(),
            columnVisibility: ObjectListingColumnVisibilityStore(defaults: defaults.defaults)
        )
    }

    private func listing(_ names: [String], sizes: [String]) -> TableListing {
        let rows = zip(names, sizes).map { name, size -> [PluginCellValue] in
            [.text("shop"), .text(name), .text("BASE TABLE"), .text(size), .text("InnoDB")]
        }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: ["Schema", "Name", "Type", "Data Length", "Engine"],
            columnTypes: Array(repeating: .text(rawType: nil), count: 5)
        )
        var items: [RowID: ObjectListingItem] = [:]
        for (index, name) in names.enumerated() {
            items[.existing(index)] = .relation(name: name, schema: nil, type: .table)
        }
        return TableListing(
            rows: tableRows, isIncomplete: false, statusMessage: nil, items: items,
            columnKeys: ["schema", "name", "kind", "data_size", "engine"]
        )
    }

    private func mount(_ model: TableListingViewModel) throws -> (ObjectListingTableCoordinator, NSTableView) {
        let coordinator = ObjectListingTableCoordinator(list: model.list, model: model)
        let scrollView = coordinator.makeScrollView()
        let table = try #require(scrollView.documentView as? NSTableView)
        return (coordinator, table)
    }

    private func key(_ name: String) -> ObjectListingItem.Key {
        ObjectListingItem.relation(name: name, schema: nil, type: .table).key
    }

    @Test("The table lists every column in the list's order and hides the ones that start hidden")
    func columnsFollowTheList() throws {
        let model = makeModel()
        model.list.show(listing(["orders"], sizes: ["16384"]), filterText: "")

        let (_, table) = try mount(model)

        #expect(table.tableColumns.map { $0.identifier.rawValue } == ["name", "data_size", "engine", "schema", "kind"])
        #expect(table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == ["name", "data_size", "engine"])
        #expect(table.headerView is ThemeTableHeaderView)
        #expect(table.tableColumns.allSatisfy { $0.headerCell is ThemeTableHeaderCell })
        #expect(table.numberOfRows == 1)
    }

    @Test("A Name cell shows the sidebar's glyph and the system font; a size cell lines up on the right")
    func cellsReadLikeAList() throws {
        let model = makeModel()
        model.list.show(listing(["orders"], sizes: ["163840"]), filterText: "")
        let (coordinator, table) = try mount(model)
        let name = try #require(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")))
        let size = try #require(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("data_size")))

        let nameCell = try #require(coordinator.tableView(table, viewFor: name, row: 0) as? NSTableCellView)
        let sizeCell = try #require(coordinator.tableView(table, viewFor: size, row: 0) as? NSTableCellView)

        #expect(nameCell.textField?.stringValue == "orders")
        #expect(nameCell.imageView?.image != nil)
        #expect(nameCell.textField?.font?.isFixedPitch == false)
        #expect(sizeCell.imageView == nil)
        #expect(sizeCell.textField?.alignment == .right)
        #expect(sizeCell.textField?.stringValue != "163840")
    }

    @Test("A header click sorts by that one column, and the arrow follows the list's sort")
    func headerSortsByOneColumn() throws {
        let model = makeModel()
        model.list.show(listing(["small", "large", "medium"], sizes: ["1", "300", "20"]), filterText: "")
        // The table holds its data source weakly, as it does the representable's coordinator.
        let (coordinator, table) = try mount(model)
        defer { withExtendedLifetime(coordinator) {} }

        table.sortDescriptors = [
            NSSortDescriptor(key: "data_size", ascending: false),
            NSSortDescriptor(key: "name", ascending: true),
        ]

        #expect(model.list.sort == ObjectListingSort(columnID: "data_size", ascending: false))
        #expect(model.list.rows.map { $0.item.name } == ["large", "medium", "small"])
        #expect(table.sortDescriptors.map { $0.key } == ["data_size"])
    }

    @Test("Selecting rows selects their objects, and a new listing keeps the selection on them")
    func selectionFollowsObjects() throws {
        let model = makeModel()
        model.list.show(listing(["customers", "orders"], sizes: ["1", "2"]), filterText: "")
        let (coordinator, table) = try mount(model)

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(model.list.selection == [key("orders")])

        model.list.show(listing(["accounts", "customers", "orders"], sizes: ["1", "1", "2"]), filterText: "")
        coordinator.sync()

        #expect(table.selectedRowIndexes == IndexSet(integer: 2))
        #expect(model.list.selection == [key("orders")])
    }

    @Test("The header's menu lists every column but Name, and hiding one hides it in every tab of the kind")
    func headerMenuHidesColumns() throws {
        let model = makeModel()
        model.list.show(listing(["orders"], sizes: ["1"]), filterText: "")
        let (coordinator, table) = try mount(model)
        let menu = coordinator.columnMenu()
        let engine = try #require(menu.items.first { ($0.representedObject as? String) == "engine" })

        #expect(!menu.items.contains { ($0.representedObject as? String) == "name" })
        #expect(engine.state == .on)

        let action = try #require(engine.action)
        _ = (engine.target as? NSObject)?.perform(action, with: engine)

        #expect(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("engine"))?.isHidden == true)
        #expect(ObjectListingColumnVisibilityStore(defaults: defaults.defaults).choices(for: .table) == ["engine": false])
    }
}
