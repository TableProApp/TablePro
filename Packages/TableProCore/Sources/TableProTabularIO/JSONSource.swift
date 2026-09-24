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
        withScanSession(slots: slots, slotCount: columns.count) { session in
            if let range = rows as? Range<Int> {
                session.scan(rows: range, body)
                return
            }
            if let list = rows as? [Int] {
                session.scan(rows: list, body)
                return
            }
            for row in rows {
                guard session.scan(row: row, body) else { return }
            }
        }
    }

    private func withScanSession(slots: JSONSlotMap, slotCount: Int, _ body: (inout JSONScanSession) -> Void) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            index.rowStarts.withUnsafeBufferPointer { rowStarts in
                index.keyTable.withLookup { lookup in
                    var session = JSONScanSession(
                        base: base,
                        count: raw.count,
                        rowStarts: rowStarts,
                        lookup: lookup,
                        slots: slots,
                        slotCount: slotCount
                    )
                    body(&session)
                }
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

    var hasRepeatedColumns: Bool { !extraSlots.isEmpty }

    @inline(__always)
    func firstSlot(of column: Int) -> Int? {
        guard column <= lastColumn else { return nil }
        let slot = firstSlots[column]
        return slot >= 0 ? slot : nil
    }

    func repeatedSlots(of column: Int) -> [Int] {
        extraSlots[column] ?? []
    }
}

private struct JSONScanSession {
    private static let bulkScanRowCount = 256
    private static let privateSlotSlack = 256

    private let base: UnsafePointer<UInt8>
    private let count: Int
    private let rowStarts: UnsafeBufferPointer<Int>
    private let lookup: JSONKeyLookup
    private let slots: JSONSlotMap
    private let slotCount: Int
    private var predictor = JSONKeyPredictor()
    private var buffer = TabularCellBuffer()
    private var scratch: [UInt8] = []
    private var keyScratch: [UInt8] = []

    init(
        base: UnsafePointer<UInt8>,
        count: Int,
        rowStarts: UnsafeBufferPointer<Int>,
        lookup: JSONKeyLookup,
        slots: JSONSlotMap,
        slotCount: Int
    ) {
        self.base = base
        self.count = count
        self.rowStarts = rowStarts
        self.lookup = lookup
        self.slots = slots
        self.slotCount = slotCount
    }

    mutating func scan(rows: Range<Int>, _ body: (Int, TabularRowCells) -> Bool) {
        reserveThreadPrivateCapacity(forRows: rows.count)
        for row in rows {
            guard scan(row: row, body) else { return }
        }
    }

    mutating func scan(rows: [Int], _ body: (Int, TabularRowCells) -> Bool) {
        reserveThreadPrivateCapacity(forRows: rows.count)
        for row in rows {
            guard scan(row: row, body) else { return }
        }
    }

    private mutating func reserveThreadPrivateCapacity(forRows rowCount: Int) {
        guard rowCount >= Self.bulkScanRowCount else { return }
        buffer.reset(slots: slotCount + Self.privateSlotSlack, fill: .missing)
        _ = buffer.withResolved { _ in true }
    }

    mutating func scan(row: Int, _ body: (Int, TabularRowCells) -> Bool) -> Bool {
        guard row >= 0, row < rowStarts.count else { return true }
        buffer.reset(slots: slotCount, fill: .missing)
        let cursor = JSONCursor(base: base, count: count, row: row)
        var ordinal = 0
        do {
            _ = try cursor.forEachMember(objectAt: rowStarts[row]) { token in
                let key = cursor.keyBytes(of: token)
                let column = token.keyHasEscapes
                    ? column(forEscapedKey: key)
                    : predictor.column(for: key, ordinal: ordinal, in: lookup)
                ordinal += 1
                guard let column, let slot = slots.firstSlot(of: column) else { return }
                fill(slot, with: token)
                guard slots.hasRepeatedColumns else { return }
                for repeated in slots.repeatedSlots(of: column) {
                    fill(repeated, with: token)
                }
            }
        } catch {
            markAllAsErrors()
        }
        return buffer.withResolved { body(row, $0) }
    }

    private mutating func column(forEscapedKey key: UnsafeBufferPointer<UInt8>) -> Int? {
        keyScratch.removeAll(keepingCapacity: true)
        JSONText.appendDecoded(key, into: &keyScratch)
        return keyScratch.withUnsafeBufferPointer { lookup.column(for: $0) }
    }

    private mutating func fill(_ slot: Int, with token: JSONMemberToken) {
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

    private mutating func markAllAsErrors() {
        for slot in 0..<slotCount {
            buffer.setEmpty(slot, kind: .error)
        }
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
