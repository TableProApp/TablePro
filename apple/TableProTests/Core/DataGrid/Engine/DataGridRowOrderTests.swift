import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DataGridRowOrderTests {
    private let rows = TableRows.from(
        queryRows: (0..<5).map { [PluginCellValue.text("\($0)")] },
        columns: ["id"],
        columnTypes: [.integer(rawType: nil)]
    )

    @Test("With no filter the display order is the storage order")
    func unfilteredReadsStorage() {
        let order = DataGridRowOrder.unfiltered

        #expect(!order.isFiltered)
        #expect(order.count(in: rows) == 5)
        #expect(order.rowID(at: 2, in: rows) == .existing(2))
        #expect(order.storageIndex(at: 4, in: rows) == 4)
        #expect(order.row(at: 1, in: rows)?.id == .existing(1))
        #expect(order.displayIndex(of: .existing(3), in: rows) == 3)
        #expect(order.displayIndex(ofStorageIndex: 3, in: rows) == 3)
    }

    @Test("A filtered order reads its own list of rows")
    func filteredReadsItsList() {
        let order = DataGridRowOrder(filteredIDs: [.existing(4), .existing(1)], revision: 1)

        #expect(order.isFiltered)
        #expect(order.count(in: rows) == 2)
        #expect(order.rowID(at: 0, in: rows) == .existing(4))
        #expect(order.storageIndex(at: 0, in: rows) == 4)
        #expect(order.row(at: 1, in: rows)?.id == .existing(1))
        #expect(order.displayIndex(of: .existing(1), in: rows) == 1)
        #expect(order.displayIndex(ofStorageIndex: 4, in: rows) == 0)
    }

    @Test("A row the filter leaves out has no display position")
    func filteredOutRowHasNoPosition() {
        let order = DataGridRowOrder(filteredIDs: [.existing(4), .existing(1)], revision: 1)

        #expect(order.displayIndex(of: .existing(2), in: rows) == nil)
        #expect(order.displayIndex(ofStorageIndex: 2, in: rows) == nil)
    }

    @Test("A filter that keeps nothing still counts as a filter")
    func emptyFilterIsFiltered() {
        let order = DataGridRowOrder(filteredIDs: [], revision: 1)

        #expect(order.isFiltered)
        #expect(order.count(in: rows) == 0)
        #expect(order.rowID(at: 0, in: rows) == nil)
        #expect(order.displayIndex(of: .existing(0), in: rows) == nil)
    }

    @Test("Positions outside the order resolve nothing")
    func outOfRangePositions() {
        let filtered = DataGridRowOrder(filteredIDs: [.existing(0)], revision: 1)

        for order in [DataGridRowOrder.unfiltered, filtered] {
            #expect(order.rowID(at: -1, in: rows) == nil)
            #expect(order.rowID(at: 5, in: rows) == nil)
            #expect(order.storageIndex(at: 9, in: rows) == nil)
            #expect(order.displayIndex(ofStorageIndex: -1, in: rows) == nil)
            #expect(order.displayIndex(ofStorageIndex: 5, in: rows) == nil)
        }
    }

    @Test("Batch conversions skip what the order does not hold")
    func batchConversions() {
        let order = DataGridRowOrder(filteredIDs: [.existing(4), .existing(1)], revision: 1)

        #expect(order.rowIDs(atDisplayIndexes: IndexSet([0, 1, 9]), in: rows) == [.existing(4), .existing(1)])
        #expect(order.displayIndexes(of: [.existing(1), .existing(3)], in: rows) == IndexSet(integer: 1))
        #expect(DataGridRowOrder.unfiltered.displayIndexes(of: [.existing(3), .inserted(UUID())], in: rows) == IndexSet(integer: 3))
    }

    @Test("A row inserted into storage is found by its identity")
    func insertedRowsResolveByIdentity() {
        var grown = rows
        let id = RowID.inserted(UUID())
        grown.insertInsertedRow(at: 0, id: id, values: [.text("new")])

        #expect(DataGridRowOrder.unfiltered.displayIndex(of: id, in: grown) == 0)
        #expect(DataGridRowOrder.unfiltered.displayIndex(of: .existing(0), in: grown) == 1)
    }
}
