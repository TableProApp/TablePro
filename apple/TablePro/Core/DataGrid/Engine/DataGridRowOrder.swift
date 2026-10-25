import Foundation

struct DataGridRowOrder: Equatable {
    private(set) var filteredIDs: [RowID]?
    private var displayIndexByID: [RowID: Int]?
    private(set) var revision: Int

    static let unfiltered = DataGridRowOrder(filteredIDs: nil, revision: 0)

    init(filteredIDs: [RowID]?, revision: Int) {
        self.filteredIDs = filteredIDs
        self.revision = revision
        if let filteredIDs {
            var index: [RowID: Int] = [:]
            index.reserveCapacity(filteredIDs.count)
            for (position, id) in filteredIDs.enumerated() {
                index[id] = position
            }
            displayIndexByID = index
        } else {
            displayIndexByID = nil
        }
    }

    var isFiltered: Bool { filteredIDs != nil }

    func count(in tableRows: TableRows) -> Int {
        filteredIDs?.count ?? tableRows.rows.count
    }

    func rowID(at displayIndex: Int, in tableRows: TableRows) -> RowID? {
        if let filteredIDs {
            guard displayIndex >= 0, displayIndex < filteredIDs.count else { return nil }
            return filteredIDs[displayIndex]
        }
        guard displayIndex >= 0, displayIndex < tableRows.rows.count else { return nil }
        return tableRows.rows[displayIndex].id
    }

    func storageIndex(at displayIndex: Int, in tableRows: TableRows) -> Int? {
        guard let id = rowID(at: displayIndex, in: tableRows) else { return nil }
        return tableRows.index(of: id)
    }

    func row(at displayIndex: Int, in tableRows: TableRows) -> Row? {
        storageIndex(at: displayIndex, in: tableRows).map { tableRows.rows[$0] }
    }

    func displayIndex(of id: RowID, in tableRows: TableRows) -> Int? {
        if let displayIndexByID {
            return displayIndexByID[id]
        }
        return tableRows.index(of: id)
    }

    func displayIndex(ofStorageIndex storageIndex: Int, in tableRows: TableRows) -> Int? {
        guard storageIndex >= 0, storageIndex < tableRows.rows.count else { return nil }
        guard isFiltered else { return storageIndex }
        return displayIndex(of: tableRows.rows[storageIndex].id, in: tableRows)
    }

    func rowIDs(atDisplayIndexes indexes: IndexSet, in tableRows: TableRows) -> [RowID] {
        indexes.compactMap { rowID(at: $0, in: tableRows) }
    }

    func displayIndexes(of ids: some Sequence<RowID>, in tableRows: TableRows) -> IndexSet {
        IndexSet(ids.compactMap { displayIndex(of: $0, in: tableRows) })
    }
}
