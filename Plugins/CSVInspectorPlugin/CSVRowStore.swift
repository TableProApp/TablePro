import Foundation
import TableProPluginKit

final class CSVRowStore {
    enum RowRef: Sendable {
        case original(Range<Int>)
        case materialized([String])
    }

    enum RowSource {
        case rawBytes(Range<Int>)
        case cells([String])
    }

    enum ColumnTransform: Sendable {
        case insert(index: Int, value: String)
        case remove(index: Int)
    }

    struct Snapshot: InspectorDataSnapshot {
        let data: Data
        let parser: CSVStreamingParser
        let rows: [RowRef]
        let columnTransforms: [ColumnTransform]

        var rowCount: Int { rows.count }

        func cells(at row: Int) -> [String] {
            guard row >= 0, row < rows.count else { return [] }
            switch rows[row] {
            case .materialized(let cells):
                return cells
            case .original(let range):
                let parsed = data.withUnsafeBytes { raw -> [String] in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
                    return parser.parseRow(UnsafeBufferPointer(start: base, count: raw.count), range: range)
                }
                return CSVRowStore.applyColumnTransforms(parsed, transforms: columnTransforms)
            }
        }

        func field(at row: Int, column: Int) -> String {
            guard row >= 0, row < rows.count, column >= 0 else { return "" }
            if !columnTransforms.isEmpty {
                let cells = self.cells(at: row)
                return column < cells.count ? cells[column] : ""
            }
            switch rows[row] {
            case .materialized(let cells):
                return column < cells.count ? cells[column] : ""
            case .original(let range):
                return data.withUnsafeBytes { raw -> String in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
                    return parser.field(UnsafeBufferPointer(start: base, count: raw.count), range: range, column: column)
                }
            }
        }
    }

    let data: Data
    private let parser: CSVStreamingParser
    private(set) var columnNames: [String]
    private var headerRef: RowRef
    private var logicalRows: [RowRef]
    private var columnTransforms: [ColumnTransform] = []

    private var cache: [Int: [String]] = [:]
    private var cacheOrder: [Int] = []
    private let cacheCapacity = 4000

    init(data: Data, dialect: CSVDialect) {
        let streamingParser = CSVStreamingParser(dialect: dialect)
        var ranges = data.withUnsafeBytes { raw -> [Range<Int>] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return streamingParser.indexRows(UnsafeBufferPointer(start: base, count: raw.count))
        }

        var resolvedColumnNames: [String] = []
        var resolvedHeaderRef: RowRef = .materialized([])
        if let first = ranges.first {
            let headerCells = data.withUnsafeBytes { raw -> [String] in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
                return streamingParser.parseRow(UnsafeBufferPointer(start: base, count: raw.count), range: first)
            }
            if Self.isLikelyHeader(headerCells) {
                resolvedColumnNames = headerCells
                resolvedHeaderRef = .original(first)
                ranges.removeFirst()
            } else {
                let synthetic = (0..<headerCells.count).map { "Column \($0 + 1)" }
                resolvedColumnNames = synthetic
                resolvedHeaderRef = .materialized(synthetic)
            }
        }

        self.data = data
        self.parser = streamingParser
        self.columnNames = resolvedColumnNames
        self.headerRef = resolvedHeaderRef
        self.logicalRows = ranges.map { .original($0) }
    }

    var rowCount: Int { logicalRows.count }
    var columnCount: Int { columnNames.count }
    var headerSource: RowSource {
        switch headerRef {
        case .original(let range) where columnTransforms.isEmpty:
            return .rawBytes(range)
        case .original(let range):
            return .cells(applyColumnTransforms(rawCells(in: range)))
        case .materialized(let cells):
            return .cells(cells)
        }
    }

    func value(row: Int, column: Int) -> String {
        let cells = self.cells(forRow: row)
        guard column >= 0, column < cells.count else { return "" }
        return cells[column]
    }

    func cells(forRow row: Int) -> [String] {
        guard row >= 0, row < logicalRows.count else { return [] }
        switch logicalRows[row] {
        case .materialized(let cells):
            return cells
        case .original(let range):
            return applyColumnTransforms(cachedRawCells(in: range))
        }
    }

    func rowSource(at row: Int) -> RowSource {
        guard row >= 0, row < logicalRows.count else { return .cells([]) }
        switch logicalRows[row] {
        case .original(let range) where columnTransforms.isEmpty:
            return .rawBytes(range)
        case .original, .materialized:
            return .cells(cells(forRow: row))
        }
    }

    func pageRows(offset: Int, limit: Int) -> [[String]] {
        let lower = max(offset, 0)
        let upper = min(lower + max(limit, 0), logicalRows.count)
        guard lower < upper else { return [] }
        return (lower..<upper).map { cells(forRow: $0) }
    }

    func snapshot() -> Snapshot {
        Snapshot(data: data, parser: parser, rows: logicalRows, columnTransforms: columnTransforms)
    }

    @discardableResult
    func setValue(_ value: String, row: Int, column: Int) -> String? {
        guard row >= 0, row < logicalRows.count, column >= 0 else { return nil }
        var current = cells(forRow: row)
        while current.count <= column {
            current.append("")
        }
        let previous = current[column]
        current[column] = value
        logicalRows[row] = .materialized(current)
        return previous
    }

    @discardableResult
    func appendRow(values: [String]) -> Int {
        logicalRows.append(.materialized(padRow(values)))
        return logicalRows.count - 1
    }

    func insertRow(_ values: [String], at index: Int) {
        let clamped = min(max(index, 0), logicalRows.count)
        logicalRows.insert(.materialized(padRow(values)), at: clamped)
    }

    @discardableResult
    func removeRow(at index: Int) -> [String]? {
        guard index >= 0, index < logicalRows.count else { return nil }
        let removed = cells(forRow: index)
        logicalRows.remove(at: index)
        return removed
    }

    @discardableResult
    func removeRows(at indexSet: IndexSet) -> [(index: Int, cells: [String])] {
        guard !indexSet.isEmpty else { return [] }
        var removed: [(index: Int, cells: [String])] = []
        removed.reserveCapacity(indexSet.count)
        var retained: [RowRef] = []
        retained.reserveCapacity(max(0, logicalRows.count - indexSet.count))
        for (i, row) in logicalRows.enumerated() {
            if indexSet.contains(i) {
                let captured: [String]
                switch row {
                case .materialized(let cells):
                    captured = cells
                case .original(let range):
                    let parsed = data.withUnsafeBytes { raw -> [String] in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
                        return parser.parseRow(UnsafeBufferPointer(start: base, count: raw.count), range: range)
                    }
                    captured = Self.applyColumnTransforms(parsed, transforms: columnTransforms)
                }
                removed.append((i, captured))
            } else {
                retained.append(row)
            }
        }
        logicalRows = retained
        return removed
    }

    func appendColumn(name: String) {
        insertColumn(at: columnNames.count, name: name, values: [])
    }

    func insertColumn(at index: Int, name: String, values: [String] = []) {
        let clamped = min(max(index, 0), columnNames.count)
        columnNames.insert(name, at: clamped)
        columnTransforms.append(.insert(index: clamped, value: ""))
        for row in logicalRows.indices {
            if case .materialized(var cells) = logicalRows[row] {
                let value = clamped < values.count ? values[clamped] : ""
                cells.insert(value, at: min(clamped, cells.count))
                logicalRows[row] = .materialized(cells)
            }
        }
        if !values.isEmpty {
            for row in logicalRows.indices where row < values.count {
                setValue(values[row], row: row, column: clamped)
            }
        }
    }

    @discardableResult
    func removeColumn(at index: Int) -> (name: String, values: [String])? {
        guard index >= 0, index < columnNames.count else { return nil }
        let name = columnNames.remove(at: index)
        var captured: [String] = []
        captured.reserveCapacity(logicalRows.count)
        for row in logicalRows.indices {
            let cells = self.cells(forRow: row)
            captured.append(index < cells.count ? cells[index] : "")
        }
        columnTransforms.append(.remove(index: index))
        for row in logicalRows.indices {
            if case .materialized(var cells) = logicalRows[row], index < cells.count {
                cells.remove(at: index)
                logicalRows[row] = .materialized(cells)
            }
        }
        return (name, captured)
    }

    @discardableResult
    func renameColumn(at index: Int, to name: String) -> String? {
        guard index >= 0, index < columnNames.count else { return nil }
        let previous = columnNames[index]
        columnNames[index] = name
        if case .original(let range) = headerRef {
            headerRef = .materialized(applyColumnTransforms(rawCells(in: range)))
        }
        if case .materialized(var cells) = headerRef {
            while cells.count <= index { cells.append("") }
            cells[index] = name
            headerRef = .materialized(cells)
        }
        return previous
    }

    private func applyColumnTransforms(_ cells: [String]) -> [String] {
        Self.applyColumnTransforms(cells, transforms: columnTransforms)
    }

    static func applyColumnTransforms(_ cells: [String], transforms: [ColumnTransform]) -> [String] {
        guard !transforms.isEmpty else { return cells }
        var result = cells
        for transform in transforms {
            switch transform {
            case .insert(let index, let value):
                result.insert(value, at: min(max(index, 0), result.count))
            case .remove(let index):
                if index >= 0, index < result.count {
                    result.remove(at: index)
                }
            }
        }
        return result
    }

    private func cachedRawCells(in range: Range<Int>) -> [String] {
        if let cached = cache[range.lowerBound] {
            return cached
        }
        let parsed = rawCells(in: range)
        cache[range.lowerBound] = parsed
        cacheOrder.append(range.lowerBound)
        if cacheOrder.count > cacheCapacity {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return parsed
    }

    private func rawCells(in range: Range<Int>) -> [String] {
        data.withUnsafeBytes { raw -> [String] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return parser.parseRow(UnsafeBufferPointer(start: base, count: raw.count), range: range)
        }
    }

    private func padRow(_ values: [String]) -> [String] {
        if values.count == columnNames.count { return values }
        if values.count < columnNames.count {
            return values + Array(repeating: "", count: columnNames.count - values.count)
        }
        return Array(values.prefix(columnNames.count))
    }

    private static func isLikelyHeader(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        let nonNumeric = cells.filter { !$0.isEmpty && Double($0) == nil }.count
        return nonNumeric * 2 >= cells.count
    }
}
