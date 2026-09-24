import Foundation
import TableProTabularIO

public extension TabularTable {
    var hasSourceLayout: Bool {
        guard columns.count == source.columnCount else { return false }
        for (index, column) in columns.enumerated() {
            guard case .source(let sourceColumn) = column.values.base, sourceColumn == index else { return false }
        }
        return true
    }

    var touchedKeys: Set<Int> {
        var keys = Set<Int>()
        for column in columns {
            keys.formUnion(column.values.edits.keys)
            keys.formUnion(column.values.patch.keys)
        }
        return keys
    }

    func outputRows(sourceHeaderNames: [String]?, copiesSourceRows: Bool = true) -> TabularOutputRows {
        TabularOutputRows(table: self, sourceHeaderNames: sourceHeaderNames, copiesSourceRows: copiesSourceRows)
    }
}

public struct TabularOutputRows: Sequence {
    public let table: TabularTable
    public let sourceHeaderNames: [String]?
    public let copiesSourceRows: Bool

    public func makeIterator() -> Iterator {
        Iterator(table: table, sourceHeaderNames: sourceHeaderNames, copiesSourceRows: copiesSourceRows)
    }

    public struct Iterator: IteratorProtocol {
        private static let blockSize = 4_096

        private let table: TabularTable
        private let layoutIsPristine: Bool
        private let touched: Set<Int>
        private let columnIDs: [TabularColumnID]
        private var pendingHeader: DelimitedOutputRow?
        private var block: [DelimitedOutputRow] = []
        private var blockPosition = 0
        private var nextRow = 0

        init(table: TabularTable, sourceHeaderNames: [String]?, copiesSourceRows: Bool) {
            self.table = table
            let pristine = copiesSourceRows && table.hasSourceLayout
            layoutIsPristine = pristine
            let touched = pristine ? table.touchedKeys : []
            self.touched = touched
            columnIDs = table.columnIDs
            if let headerKey = table.headerRowKey {
                let names = table.columns.map(\.name)
                let headerIsPristine = pristine && table.isSourceKey(headerKey)
                    && !touched.contains(headerKey) && sourceHeaderNames == names
                pendingHeader = headerIsPristine ? .source(headerKey) : .fields(names)
            }
        }

        public mutating func next() -> DelimitedOutputRow? {
            if let header = pendingHeader {
                pendingHeader = nil
                return header
            }
            if blockPosition >= block.count {
                guard nextRow < table.rowCount else { return nil }
                fillBlock()
            }
            defer { blockPosition += 1 }
            return block[blockPosition]
        }

        private mutating func fillBlock() {
            let end = Swift.min(table.rowCount, nextRow + Self.blockSize)
            let range = nextRow..<end
            nextRow = end
            blockPosition = 0
            block.removeAll(keepingCapacity: true)
            let layoutIsPristine = layoutIsPristine
            let touched = touched
            var rewritten: [Int: [String]] = [:]
            let table = table
            let needsRewrite = range.filter { logicalRow -> Bool in
                let key = table.key(atRow: logicalRow)
                let copiesSource = layoutIsPristine && table.isSourceKey(key) && !touched.contains(key)
                return !copiesSource
            }
            if !needsRewrite.isEmpty {
                let count = columnIDs.count
                table.scan(columns: columnIDs, logicalRows: needsRewrite) { logicalRow, cells in
                    rewritten[logicalRow] = (0..<count).map { cells.string(at: $0) }
                    return true
                }
            }
            for logicalRow in range {
                if let fields = rewritten[logicalRow] {
                    block.append(.fields(fields))
                } else {
                    block.append(.source(table.key(atRow: logicalRow)))
                }
            }
        }
    }
}
