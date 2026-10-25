import Foundation
import TableProPluginKit

struct DataGridColumnID: Hashable, Sendable {
    let name: String
    let occurrence: Int

    var stringValue: String {
        occurrence == 0 ? name : "\(name)#\(occurrence)"
    }
}

struct DataGridColumn: Equatable {
    let id: DataGridColumnID
    let dataIndex: Int
    let type: ColumnType?
    let comment: String?

    var name: String { id.name }
}

struct DataGridColumnSet: Equatable {
    private(set) var columns: [DataGridColumn]
    private(set) var frozenCount: Int

    private var positionByDataIndex: [Int: Int]
    private var positionByID: [DataGridColumnID: Int]

    static let empty = DataGridColumnSet(columns: [], frozenCount: 0)

    init(columns: [DataGridColumn], frozenCount: Int) {
        self.columns = columns
        self.frozenCount = max(0, min(frozenCount, columns.count))
        var byData: [Int: Int] = [:]
        var byID: [DataGridColumnID: Int] = [:]
        byData.reserveCapacity(columns.count)
        byID.reserveCapacity(columns.count)
        for (position, column) in columns.enumerated() {
            byData[column.dataIndex] = position
            byID[column.id] = position
        }
        self.positionByDataIndex = byData
        self.positionByID = byID
    }

    init(tableRows: TableRows, layout: ColumnLayoutState) {
        let ids = Self.columnIDs(for: tableRows.columns)
        var all: [DataGridColumn] = []
        all.reserveCapacity(ids.count)
        for (dataIndex, id) in ids.enumerated() where !layout.hiddenColumns.contains(id.name) {
            all.append(DataGridColumn(
                id: id,
                dataIndex: dataIndex,
                type: dataIndex < tableRows.columnTypes.count ? tableRows.columnTypes[dataIndex] : nil,
                comment: tableRows.columnComments[id.name]
            ))
        }
        let ordered = Self.applyingOrder(layout.columnOrder, to: all)
        self.init(columns: ordered, frozenCount: layout.frozenColumnCount)
    }

    static func columnIDs(for names: [String]) -> [DataGridColumnID] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let occurrence = seen[name, default: 0]
            seen[name] = occurrence + 1
            return DataGridColumnID(name: name, occurrence: occurrence)
        }
    }

    private static func applyingOrder(_ order: [String]?, to columns: [DataGridColumn]) -> [DataGridColumn] {
        guard let order, !order.isEmpty else { return columns }
        var buckets: [String: [DataGridColumn]] = [:]
        for column in columns {
            buckets[column.name, default: []].append(column)
        }
        var result: [DataGridColumn] = []
        result.reserveCapacity(columns.count)
        for name in order {
            guard var bucket = buckets[name], !bucket.isEmpty else { continue }
            result.append(bucket.removeFirst())
            buckets[name] = bucket
        }
        let placed = Set(result.map(\.id))
        result.append(contentsOf: columns.filter { !placed.contains($0.id) })
        return result
    }

    var count: Int { columns.count }
    var isEmpty: Bool { columns.isEmpty }

    var frozenColumns: ArraySlice<DataGridColumn> { columns.prefix(frozenCount) }

    func column(at displayPosition: Int) -> DataGridColumn? {
        guard displayPosition >= 0, displayPosition < columns.count else { return nil }
        return columns[displayPosition]
    }

    func column(id: DataGridColumnID) -> DataGridColumn? {
        positionByID[id].map { columns[$0] }
    }

    func displayPosition(ofDataIndex dataIndex: Int) -> Int? {
        positionByDataIndex[dataIndex]
    }

    func displayPosition(of id: DataGridColumnID) -> Int? {
        positionByID[id]
    }

    func dataIndex(atDisplayPosition displayPosition: Int) -> Int? {
        column(at: displayPosition)?.dataIndex
    }

    func isFrozen(displayPosition: Int) -> Bool {
        displayPosition >= 0 && displayPosition < frozenCount
    }

    var orderedNames: [String] { columns.map(\.name) }

    func withFrozenCount(_ count: Int) -> DataGridColumnSet {
        DataGridColumnSet(columns: columns, frozenCount: count)
    }

    func moving(from source: Int, to destination: Int) -> DataGridColumnSet {
        guard source != destination, columns.indices.contains(source), columns.indices.contains(destination) else {
            return self
        }
        var reordered = columns
        let moved = reordered.remove(at: source)
        reordered.insert(moved, at: destination)
        return DataGridColumnSet(columns: reordered, frozenCount: frozenCount)
    }
}
