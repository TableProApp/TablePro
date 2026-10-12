import Foundation
import TableProTabularIO

public struct TabularColumn: Sendable, Equatable {
    public let id: TabularColumnID
    public var name: String
    public var values: ColumnValues

    public init(id: TabularColumnID, name: String, values: ColumnValues) {
        self.id = id
        self.name = name
        self.values = values
    }
}

public struct TabularTable: Sendable {
    public let source: any TabularSource
    public private(set) var columns: [TabularColumn]
    public private(set) var rowOrder: TabularRowOrder
    public private(set) var headerRowKey: Int?
    public private(set) var generation: Int
    private var nextRowKey: Int
    private var nextColumnID: Int

    public init(source: any TabularSource, usesFirstRowAsHeader: Bool) {
        self.source = source
        let hasHeader = usesFirstRowAsHeader && source.intrinsicColumnNames == nil && source.rowCount > 0
        let headerCells = hasHeader ? source.cells(row: 0) : []
        let names = source.intrinsicColumnNames
        var built: [TabularColumn] = []
        built.reserveCapacity(source.columnCount)
        for column in 0..<source.columnCount {
            let name: String
            if let names, column < names.count {
                name = names[column]
            } else if column < headerCells.count {
                name = headerCells[column].text
            } else {
                name = ""
            }
            built.append(TabularColumn(id: TabularColumnID(rawValue: column), name: name, values: ColumnValues(base: .source(column))))
        }
        columns = built
        headerRowKey = hasHeader ? 0 : nil
        rowOrder = .range((hasHeader ? 1 : 0)..<source.rowCount)
        generation = 0
        nextRowKey = source.rowCount
        nextColumnID = source.columnCount
    }

    public var rowCount: Int { rowOrder.count }
    public var columnCount: Int { columns.count }
    public var columnIDs: [TabularColumnID] { columns.map(\.id) }

    public func columnIndex(of id: TabularColumnID) -> Int? {
        columns.firstIndex { $0.id == id }
    }

    public func column(_ id: TabularColumnID) -> TabularColumn? {
        columns.first { $0.id == id }
    }

    public func key(atRow logicalRow: Int) -> Int {
        rowOrder.key(at: logicalRow)
    }

    public func isSourceKey(_ key: Int) -> Bool {
        key < source.rowCount
    }

    public func cell(row logicalRow: Int, column columnIndex: Int) -> TabularCell {
        cell(key: key(atRow: logicalRow), column: columns[columnIndex])
    }

    public func cell(key: Int, column: TabularColumn) -> TabularCell {
        let values = column.values
        if let edited = values.edits[key] {
            return edited
        }
        if let slot = values.patch.slot(forKey: key) {
            return values.patch.values.cell(at: slot)
        }
        return baseCell(key: key, base: values.base)
    }

    public func cells(row logicalRow: Int) -> [TabularCell] {
        let key = key(atRow: logicalRow)
        return columns.map { cell(key: key, column: $0) }
    }

    public var hasEdits: Bool {
        columns.contains { !$0.values.edits.isEmpty }
    }

    func baseCell(key: Int, base: ColumnBase) -> TabularCell {
        switch base {
        case .source(let sourceColumn):
            guard isSourceKey(key) else { return source.absentCell }
            return source.cell(row: key, column: sourceColumn)
        case .constant(let cell):
            return cell
        case .dense(let store):
            guard key < store.count else { return source.absentCell }
            return store.cell(at: key)
        }
    }

    public mutating func bumpGeneration() {
        generation += 1
    }

    public mutating func setCell(_ cell: TabularCell, row logicalRow: Int, column columnIndex: Int) {
        let key = key(atRow: logicalRow)
        columns[columnIndex].values.edits[key] = cell
        generation += 1
    }

    public mutating func setCells(_ updates: [(key: Int, columnID: TabularColumnID, cell: TabularCell)]) {
        guard !updates.isEmpty else { return }
        var indexByID: [TabularColumnID: Int] = [:]
        for (index, column) in columns.enumerated() {
            indexByID[column.id] = index
        }
        for update in updates {
            guard let index = indexByID[update.columnID] else { continue }
            columns[index].values.edits[update.key] = update.cell
        }
        generation += 1
    }

    @discardableResult
    public mutating func insertRows(_ rows: [[TabularCell]], at logicalRow: Int) -> [Int] {
        guard !rows.isEmpty else { return [] }
        let keys = (0..<rows.count).map { nextRowKey + $0 }
        nextRowKey += rows.count
        for (offset, row) in rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() where columnIndex < columns.count {
                columns[columnIndex].values.edits[keys[offset]] = cell
            }
        }
        rowOrder = rowOrder.inserting(keys, at: logicalRow)
        generation += 1
        return keys
    }

    public mutating func insertRows(keys: [Int], at logicalRow: Int) {
        guard !keys.isEmpty else { return }
        rowOrder = rowOrder.inserting(keys, at: logicalRow)
        generation += 1
    }

    public mutating func deleteRows(_ logicalRows: IndexSet) {
        guard !logicalRows.isEmpty else { return }
        rowOrder = rowOrder.removing(logicalRows: logicalRows)
        generation += 1
    }

    public mutating func deleteRows(keys: Set<Int>) {
        guard !keys.isEmpty else { return }
        rowOrder = rowOrder.removing(keys: keys)
        generation += 1
    }

    public mutating func replaceRowOrder(_ order: TabularRowOrder) {
        rowOrder = order
        generation += 1
    }

    @discardableResult
    public mutating func insertColumn(named name: String, at index: Int, fill: TabularCell? = nil) -> TabularColumnID {
        let id = TabularColumnID(rawValue: nextColumnID)
        nextColumnID += 1
        let column = TabularColumn(id: id, name: name, values: ColumnValues(base: .constant(fill ?? source.absentCell)))
        columns.insert(column, at: min(max(0, index), columns.count))
        generation += 1
        return id
    }

    @discardableResult
    public mutating func insertColumn(named name: String, at index: Int, values: ColumnValues) -> TabularColumnID {
        let id = TabularColumnID(rawValue: nextColumnID)
        nextColumnID += 1
        columns.insert(TabularColumn(id: id, name: name, values: values), at: min(max(0, index), columns.count))
        generation += 1
        return id
    }

    public mutating func deleteColumns(_ ids: Set<TabularColumnID>) {
        guard !ids.isEmpty else { return }
        columns.removeAll { ids.contains($0.id) }
        generation += 1
    }

    public mutating func renameColumn(_ id: TabularColumnID, to name: String) {
        guard let index = columnIndex(of: id) else { return }
        columns[index].name = name
        generation += 1
    }

    public mutating func moveColumn(_ id: TabularColumnID, to destination: Int) {
        guard let index = columnIndex(of: id) else { return }
        let column = columns.remove(at: index)
        columns.insert(column, at: min(max(0, destination), columns.count))
        generation += 1
    }

    public mutating func replaceValues(of id: TabularColumnID, with values: ColumnValues) {
        guard let index = columnIndex(of: id) else { return }
        columns[index].values = values
        generation += 1
    }

    public mutating func setUsesFirstRowAsHeader(_ enabled: Bool) {
        guard source.intrinsicColumnNames == nil else { return }
        if enabled {
            guard headerRowKey == nil, rowCount > 0 else { return }
            let key = key(atRow: 0)
            for index in columns.indices {
                columns[index].name = cell(key: key, column: columns[index]).text
            }
            rowOrder = rowOrder.removing(logicalRows: IndexSet(integer: 0))
            headerRowKey = key
        } else {
            guard let key = headerRowKey else { return }
            for index in columns.indices {
                let name = columns[index].name
                if cell(key: key, column: columns[index]).text != name {
                    columns[index].values.edits[key] = .text(name)
                }
                columns[index].name = ""
            }
            rowOrder = rowOrder.inserting([key], at: 0)
            headerRowKey = nil
        }
        generation += 1
    }
}
