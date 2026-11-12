//
//  ObjectListingListTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ObjectListingListTests {
    private let defaults: EphemeralDefaults

    init() throws {
        defaults = try EphemeralDefaults()
    }

    private func makeList(kind: SidebarObjectKind = .table) -> ObjectListingList {
        ObjectListingList(
            kind: kind,
            containerName: "shop",
            visibility: ObjectListingColumnVisibilityStore(defaults: defaults.defaults),
            formatter: { ObjectListingValueFormatter(locale: Locale(identifier: "en_US"), timeZone: .current) }
        )
    }

    /// A Tables listing of `names`, each row carrying a size in bytes.
    private func listing(_ names: [String], sizes: [String]? = nil) -> TableListing {
        let rows = names.enumerated().map { index, name -> [PluginCellValue] in
            [.text("shop"), .text(name), .text(sizes?[index] ?? "16384")]
        }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: ["Schema", "Name", "Data Length"],
            columnTypes: Array(repeating: .text(rawType: nil), count: 3)
        )
        var items: [RowID: ObjectListingItem] = [:]
        for (index, name) in names.enumerated() {
            items[.existing(index)] = .relation(name: name, schema: nil, type: .table)
        }
        return TableListing(
            rows: tableRows, isIncomplete: false, statusMessage: nil, items: items,
            columnKeys: ["schema", "name", "data_size"]
        )
    }

    private func key(_ name: String) -> ObjectListingItem.Key {
        ObjectListingItem.relation(name: name, schema: nil, type: .table).key
    }

    private func names(_ list: ObjectListingList) -> [String] {
        list.rows.map { $0.item.name }
    }

    @Test("A listing reaches the list in its own order, formatted, with its columns")
    func listingReachesTheList() {
        let list = makeList()

        list.show(listing(["orders", "customers"], sizes: ["163840", "16384"]), filterText: "")

        #expect(names(list) == ["orders", "customers"])
        #expect(list.columns.map { $0.id } == ["name", "data_size", "schema"])
        #expect(list.shownColumns.map { $0.id } == ["name", "data_size"])
        #expect(list.rows.first?.texts[2] != "163840")
    }

    // Held by object, so a table created above the selected one does not move the selection to its neighbour.
    @Test("A new listing keeps the selection on the same objects, and drops the ones that went")
    func selectionFollowsItsObjects() {
        let list = makeList()
        list.show(listing(["customers", "orders"]), filterText: "")
        list.select([key("orders")])

        list.show(listing(["accounts", "customers", "orders"]), filterText: "")
        #expect(list.selectedItems.map { $0.name } == ["orders"])

        list.show(listing(["accounts", "customers"]), filterText: "")
        #expect(list.selection.isEmpty)
    }

    @Test("A sort orders the rows by the column's values, keeps the selection, and orders the next listing too")
    func sortOrdersTheRows() {
        let list = makeList()
        var sortChanges = 0
        list.onSortChange = { sortChanges += 1 }
        list.show(listing(["small", "large", "medium"], sizes: ["16384", "2050000000", "163840"]), filterText: "")
        list.select([key("small")])

        list.setSort(ObjectListingSort(columnID: "data_size", ascending: false))

        #expect(names(list) == ["large", "medium", "small"])
        #expect(list.selectedItems.map { $0.name } == ["small"])
        #expect(sortChanges == 1)

        list.show(listing(["tiny", "large"], sizes: ["1", "2050000000"]), filterText: "")
        #expect(names(list) == ["large", "tiny"])
    }

    @Test("The filter narrows the rows, and a row it hides leaves the selection")
    func filterNarrowsTheRows() {
        let list = makeList()
        list.show(listing(["orders", "order_items", "customers"]), filterText: "")
        list.select([key("orders"), key("customers")])

        list.applyFilter("ORDER")

        #expect(names(list) == ["orders", "order_items"])
        #expect(list.selectedItems.map { $0.name } == ["orders"])

        list.applyFilter("")
        #expect(names(list) == ["orders", "order_items", "customers"])
    }

    @Test("A row with no object behind it is not listed, since nothing could open it")
    func rowsWithoutAnObjectAreLeftOut() {
        let list = makeList()
        let source = listing(["orders", "customers"])
        let partial = TableListing(
            rows: source.rows, isIncomplete: false, statusMessage: nil,
            items: [.existing(1): .relation(name: "customers", schema: nil, type: .table)],
            columnKeys: source.columnKeys
        )

        list.show(partial, filterText: "")

        #expect(names(list) == ["customers"])
    }

    @Test("Rows replaced move the revision, and a selection alone leaves it, so the table reloads only for rows")
    func revisionMovesWithRows() {
        let list = makeList()
        list.show(listing(["orders"]), filterText: "")
        let shown = list.revision

        list.select([key("orders")])
        #expect(list.revision == shown)

        list.setSort(ObjectListingSort(columnID: "name", ascending: false))
        #expect(list.revision != shown)
    }

    @Test("A column the reader shows or hides stays that way for every tab of the kind, and Name never hides")
    func columnChoicesPersistPerKind() throws {
        let list = makeList()
        list.show(listing(["orders"]), filterText: "")
        let schema = try #require(list.columns.first { $0.id == "schema" })
        let size = try #require(list.columns.first { $0.id == "data_size" })

        list.setColumn("schema", shown: true)
        list.setColumn("data_size", shown: false)
        list.setColumn("name", shown: false)

        #expect(list.isShown(schema))
        #expect(!list.isShown(size))
        #expect(list.shownColumns.map { $0.id } == ["name", "schema"])

        let nextTab = makeList()
        nextTab.show(listing(["customers"]), filterText: "")
        #expect(nextTab.shownColumns.map { $0.id } == ["name", "schema"])

        let views = makeList(kind: .view)
        views.show(listing(["recent_orders"]), filterText: "")
        #expect(views.shownColumns.map { $0.id } == ["name", "data_size"])
    }

    @Test("A column the listing does not have is not recorded")
    func unknownColumnsAreNotRecorded() {
        let list = makeList()
        list.show(listing(["orders"]), filterText: "")

        list.setColumn("engine", shown: true)

        #expect(ObjectListingColumnVisibilityStore(defaults: defaults.defaults).choices(for: .table).isEmpty)
    }
}
