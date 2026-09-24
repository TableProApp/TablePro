import Foundation

public struct JSONSource: TabularSource {
    public let bytes: Data
    public let index: JSONTableIndex
    public let keys: [String]

    public init(bytes: Data, index: JSONTableIndex) {
        self.bytes = bytes
        self.index = index
        keys = index.keys
    }

    public var shape: JSONTableShape { index.shape }

    public var rowCount: Int { index.rowCount }

    public var columnCount: Int { keys.count }

    public var intrinsicColumnNames: [String]? { keys }

    public var absentCell: TabularCell { .missing }

    public func objectLayout(ofRow row: Int) throws -> JSONObjectLayout {
        try bytes.withUnsafeBytes { raw in
            try JSONRowParser.parseObject(in: raw.bindMemory(to: UInt8.self), at: index.rowStarts[row], row: row)
        }
    }

    public func objectRange(ofRow row: Int) throws -> Range<Int> {
        let start = index.rowStarts[row]
        let end = try bytes.withUnsafeBytes { raw in
            try JSONRowParser.objectEnd(in: raw.bindMemory(to: UInt8.self), at: start, row: row)
        }
        return start..<end
    }

    public func cell(row: Int, column: Int) -> TabularCell {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return .missing }
        var result = TabularCell.missing
        scan(columns: [column], rows: CollectionOfOne(row)) { _, cells in
            result = TabularCell(kind: cells.kinds[0], text: cells.string(at: 0))
            return false
        }
        return result
    }

    public func cells(row: Int) -> [TabularCell] {
        guard row >= 0, row < rowCount else { return [] }
        var result: [TabularCell] = []
        scan(columns: Array(0..<columnCount), rows: CollectionOfOne(row)) { _, cells in
            result = (0..<cells.count).map { TabularCell(kind: cells.kinds[$0], text: cells.string(at: $0)) }
            return false
        }
        return result
    }

    public func scan<Rows: Collection>(
        columns: [Int],
        rows: Rows,
        _ body: (Int, TabularRowCells) -> Bool
    ) where Rows.Element == Int {
        guard let slots = JSONSlotMap(columns: columns) else { return }
        let keyTable = index.keyTable
        let rowStarts = index.rowStarts
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var reader = JSONCellReader(base: base, count: raw.count, slots: columns.count)
            var predictor = JSONKeyPredictor()
            for row in rows {
                guard row >= 0, row < rowStarts.count else { continue }
                reader.begin()
                let cursor = JSONCursor(base: base, count: raw.count, row: row)
                var ordinal = 0
                do {
                    _ = try cursor.forEachMember(objectAt: rowStarts[row]) { token in
                        let column = token.keyHasEscapes
                            ? reader.column(forEscapedKey: cursor.keyBytes(of: token), in: keyTable)
                            : predictor.column(for: cursor.keyBytes(of: token), ordinal: ordinal, in: keyTable)
                        ordinal += 1
                        guard let column else { return }
                        slots.forEachSlot(of: column) { reader.fill($0, with: token) }
                    }
                } catch {
                    reader.markAllAsErrors()
                }
                if !reader.deliver(row: row, to: body) { return }
            }
        }
    }

    internal func firstInvalidRow(in rows: Range<Int>, isCancelled: () -> Bool) throws -> JSONTableError? {
        let rowStarts = index.rowStarts
        return try bytes.withUnsafeBytes { raw -> JSONTableError? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            for row in rows {
                if row & 4_095 == 0, isCancelled() { throw TabularCancellation() }
                do {
                    _ = try JSONCursor(base: base, count: raw.count, row: row).forEachMember(objectAt: rowStarts[row]) { _ in }
                } catch let error as JSONTableError {
                    return error
                }
            }
            return nil
        }
    }
}

private struct JSONSlotMap {
    private let lastColumn: Int
    private var firstSlots: [Int]
    private var extraSlots: [Int: [Int]] = [:]

    init?(columns: [Int]) {
        guard let lastColumn = columns.max(), lastColumn >= 0 else { return nil }
        self.lastColumn = lastColumn
        firstSlots = [Int](repeating: -1, count: lastColumn + 1)
        for (slot, column) in columns.enumerated() where column >= 0 {
            guard firstSlots[column] >= 0 else {
                firstSlots[column] = slot
                continue
            }
            extraSlots[column, default: []].append(slot)
        }
    }

    @inline(__always)
    func forEachSlot(of column: Int, _ body: (Int) -> Void) {
        guard column <= lastColumn else { return }
        let slot = firstSlots[column]
        guard slot >= 0 else { return }
        body(slot)
        guard !extraSlots.isEmpty, let extra = extraSlots[column] else { return }
        extra.forEach(body)
    }
}

private struct JSONCellReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    let slots: Int
    private var buffer = TabularCellBuffer()
    private var scratch: [UInt8] = []
    private var keyScratch: [UInt8] = []

    init(base: UnsafePointer<UInt8>, count: Int, slots: Int) {
        self.base = base
        self.count = count
        self.slots = slots
    }

    mutating func begin() {
        buffer.reset(slots: slots, fill: .missing)
    }

    mutating func column(forEscapedKey key: UnsafeBufferPointer<UInt8>, in table: JSONKeyTable) -> Int? {
        keyScratch.removeAll(keepingCapacity: true)
        JSONText.appendDecoded(key, into: &keyScratch)
        return keyScratch.withUnsafeBufferPointer { table.column(for: $0) }
    }

    mutating func fill(_ slot: Int, with token: JSONMemberToken) {
        let range = token.valueRange
        switch token.kind {
        case .text:
            let content = UnsafeBufferPointer(start: base + range.lowerBound + 1, count: range.count - 2)
            guard token.valueNeedsRewrite else {
                buffer.setExternal(slot, content, kind: .text)
                return
            }
            scratch.removeAll(keepingCapacity: true)
            JSONText.appendDecoded(content, into: &scratch)
            setScratch(slot, kind: .text)
        case .object, .array:
            let value = UnsafeBufferPointer(start: base + range.lowerBound, count: range.count)
            guard token.valueNeedsRewrite else {
                buffer.setExternal(slot, value, kind: token.kind)
                return
            }
            scratch.removeAll(keepingCapacity: true)
            JSONText.appendCompact(value, into: &scratch)
            setScratch(slot, kind: token.kind)
        default:
            buffer.setExternal(slot, UnsafeBufferPointer(start: base + range.lowerBound, count: range.count), kind: token.kind)
        }
    }

    mutating func markAllAsErrors() {
        for slot in 0..<slots {
            buffer.setEmpty(slot, kind: .error)
        }
    }

    mutating func deliver(row: Int, to body: (Int, TabularRowCells) -> Bool) -> Bool {
        buffer.withResolved { body(row, $0) }
    }

    private mutating func setScratch(_ slot: Int, kind: TabularCellKind) {
        let bytes = scratch
        bytes.withUnsafeBufferPointer { buffer.setCopy(slot, $0, kind: kind) }
    }
}

public enum JSONSourceBuilder {
    public static func build(
        bytes: Data,
        fileKind: JSONTableFileKind,
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> JSONSource {
        let index = try bytes.withUnsafeBytes { raw -> JSONTableIndex in
            try JSONTableIndexer.index(
                raw.bindMemory(to: UInt8.self),
                fileKind: fileKind,
                progress: { progress?($0 * 0.6) },
                isCancelled: isCancelled
            )
        }
        let source = JSONSource(bytes: bytes, index: index)
        try await validateRows(of: source, progress: { progress?(0.6 + $0 * 0.4) }, isCancelled: isCancelled)
        return source
    }

    private static func validateRows(
        of source: JSONSource,
        progress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        let chunks = TabularChunking.ranges(count: source.rowCount)
        guard !chunks.isEmpty else { return }
        let total = chunks.count
        let earliest = try await withThrowingTaskGroup(of: JSONTableError?.self) { group -> JSONTableError? in
            for chunk in chunks {
                group.addTask {
                    if isCancelled() { throw TabularCancellation() }
                    return try source.firstInvalidRow(in: chunk, isCancelled: isCancelled)
                }
            }
            var earliest: JSONTableError?
            var finished = 0
            for try await failure in group {
                finished += 1
                progress(Double(finished) / Double(total))
                guard let failure else { continue }
                if let current = earliest, (current.row ?? 0) <= (failure.row ?? 0) { continue }
                earliest = failure
            }
            return earliest
        }
        if let earliest { throw earliest }
    }
}
