import Foundation

public struct DelimitedSource: TabularSource {
    public let bytes: Data
    public let index: DelimitedRowIndex
    public let dialect: DelimitedDialect
    public let byteEncoding: TabularTextEncoding
    public let fieldCountOfFirstRow: Int
    public let maximumFieldCount: Int
    public let raggedRowCount: Int

    public init(
        bytes: Data,
        index: DelimitedRowIndex,
        dialect: DelimitedDialect,
        byteEncoding: TabularTextEncoding,
        fieldCountOfFirstRow: Int,
        maximumFieldCount: Int,
        raggedRowCount: Int
    ) {
        self.bytes = bytes
        self.index = index
        self.dialect = dialect
        self.byteEncoding = byteEncoding
        self.fieldCountOfFirstRow = fieldCountOfFirstRow
        self.maximumFieldCount = maximumFieldCount
        self.raggedRowCount = raggedRowCount
    }

    public var rowCount: Int { index.rowCount }

    public var columnCount: Int { maximumFieldCount }

    public var intrinsicColumnNames: [String]? { nil }

    public var absentCell: TabularCell { .text("") }

    public func rawRange(ofRow row: Int) -> Range<Int> {
        index.range(ofRow: row)
    }

    public func withDialect(_ newDialect: DelimitedDialect) -> DelimitedSource {
        DelimitedSource(
            bytes: bytes,
            index: index,
            dialect: newDialect,
            byteEncoding: byteEncoding,
            fieldCountOfFirstRow: fieldCountOfFirstRow,
            maximumFieldCount: maximumFieldCount,
            raggedRowCount: raggedRowCount
        )
    }

    public func cell(row: Int, column: Int) -> TabularCell {
        guard row >= 0, row < rowCount, column >= 0 else { return .text("") }
        let range = rawRange(ofRow: row)
        let reader = DelimitedFieldReader(dialect: dialect)
        var scratch: [UInt8] = []
        var value = ""
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            reader.field(in: base, range: range, column: column, scratch: &scratch) { content in
                guard let content else { return }
                value = TabularTextCodec.string(from: content, encoding: byteEncoding)
            }
        }
        return .text(value)
    }

    public func cells(row: Int) -> [TabularCell] {
        guard row >= 0, row < rowCount else { return [] }
        var fields = decodedFields(row: row)
        if fields.count < columnCount {
            fields.append(contentsOf: repeatElement("", count: columnCount - fields.count))
        }
        return fields.map { TabularCell.text($0) }
    }

    public func decodedFields(row: Int) -> [String] {
        guard row >= 0, row < index.rowCount else { return [] }
        let range = index.range(ofRow: row)
        let reader = DelimitedFieldReader(dialect: dialect)
        var scratch: [UInt8] = []
        var result: [String] = []
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            reader.forEachField(in: base, range: range, scratch: &scratch) { _, content in
                result.append(TabularTextCodec.string(from: content, encoding: byteEncoding))
                return true
            }
        }
        return result
    }

    public func scan<Rows: Collection>(
        columns: [Int],
        rows: Rows,
        _ body: (Int, TabularRowCells) -> Bool
    ) where Rows.Element == Int {
        guard !columns.isEmpty else { return }
        let reader = DelimitedFieldReader(dialect: dialect)
        let lastRequested = columns.max() ?? 0
        var slotsByColumn = [[Int]](repeating: [], count: lastRequested + 1)
        for (slot, column) in columns.enumerated() where column >= 0 {
            slotsByColumn[column].append(slot)
        }
        let encoding = byteEncoding
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let fileStart = UnsafeRawPointer(base)
            let fileEnd = fileStart + raw.count
            var scratch: [UInt8] = []
            var buffer = TabularCellBuffer()
            buffer.reserveThreadPrivateCapacity(slots: columns.count)
            for row in rows {
                guard row >= 0, row < rowCount else { continue }
                buffer.reset(slots: columns.count, fill: .text)
                reader.forEachField(in: base, range: rawRange(ofRow: row), scratch: &scratch) { column, content in
                    guard column <= lastRequested else { return false }
                    for slot in slotsByColumn[column] {
                        let pointer = UnsafeRawPointer(content.baseAddress)
                        let pointsIntoFile = pointer.map { $0 >= fileStart && $0 < fileEnd } ?? false
                        if pointsIntoFile, encoding == .utf8 || TabularTextCodec.isASCII(content) {
                            buffer.setExternal(slot, content, kind: .text)
                        } else {
                            buffer.setTranscoded(slot, content, from: encoding, kind: .text)
                        }
                    }
                    return column < lastRequested
                }
                let keepGoing = buffer.withResolved { body(row, $0) }
                if !keepGoing { return }
            }
        }
    }
}

public enum DelimitedSourceBuilder {
    public static func build(
        bytes: Data,
        dialect: DelimitedDialect,
        byteEncoding: TabularTextEncoding,
        contentStart: Int,
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> DelimitedSource {
        let index = try bytes.withUnsafeBytes { raw -> DelimitedRowIndex in
            let buffer = raw.bindMemory(to: UInt8.self)
            return try DelimitedRowIndexer.index(
                buffer,
                dialect: dialect,
                contentStart: contentStart,
                progress: { progress?($0 * 0.6) },
                isCancelled: isCancelled
            )
        }
        let counts = try await fieldCounts(
            bytes: bytes,
            index: index,
            dialect: dialect,
            progress: { progress?(0.6 + $0 * 0.4) },
            isCancelled: isCancelled
        )
        return DelimitedSource(
            bytes: bytes,
            index: index,
            dialect: dialect,
            byteEncoding: byteEncoding,
            fieldCountOfFirstRow: counts.first,
            maximumFieldCount: counts.maximum,
            raggedRowCount: counts.ragged
        )
    }

    private struct FieldCounts: Sendable {
        var first = 0
        var maximum = 0
        var ragged = 0
    }

    private static func fieldCounts(
        bytes: Data,
        index: DelimitedRowIndex,
        dialect: DelimitedDialect,
        progress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> FieldCounts {
        let rowCount = index.rowCount
        guard rowCount > 0 else { return FieldCounts() }
        let first = countFields(bytes: bytes, index: index, dialect: dialect, rows: 0..<1).maximum
        let chunks = TabularChunking.ranges(count: rowCount)
        let reference = first
        let total = chunks.count
        return try await withThrowingTaskGroup(of: FieldCounts.self) { group in
            for chunk in chunks {
                group.addTask {
                    if isCancelled() { throw TabularCancellation() }
                    var counts = countFields(bytes: bytes, index: index, dialect: dialect, rows: chunk)
                    counts.ragged = countRagged(bytes: bytes, index: index, dialect: dialect, rows: chunk, reference: reference)
                    return counts
                }
            }
            var merged = FieldCounts(first: first, maximum: first, ragged: 0)
            var finished = 0
            for try await counts in group {
                merged.maximum = max(merged.maximum, counts.maximum)
                merged.ragged += counts.ragged
                finished += 1
                progress(Double(finished) / Double(total))
            }
            return merged
        }
    }

    private static func countFields(
        bytes: Data,
        index: DelimitedRowIndex,
        dialect: DelimitedDialect,
        rows: Range<Int>
    ) -> FieldCounts {
        let reader = DelimitedFieldReader(dialect: dialect)
        var counts = FieldCounts()
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var scratch: [UInt8] = []
            for row in rows {
                counts.maximum = max(counts.maximum, reader.fieldCount(in: base, range: index.range(ofRow: row), scratch: &scratch))
            }
        }
        return counts
    }

    private static func countRagged(
        bytes: Data,
        index: DelimitedRowIndex,
        dialect: DelimitedDialect,
        rows: Range<Int>,
        reference: Int
    ) -> Int {
        let reader = DelimitedFieldReader(dialect: dialect)
        var ragged = 0
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var scratch: [UInt8] = []
            for row in rows where reader.fieldCount(in: base, range: index.range(ofRow: row), scratch: &scratch) != reference {
                ragged += 1
            }
        }
        return ragged
    }
}

public enum TabularChunking {
    public static let minimumChunkSize = 4_096

    public static func ranges(count: Int, parts: Int = ProcessInfo.processInfo.activeProcessorCount * 2) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let desired = max(1, min(parts, (count + minimumChunkSize - 1) / minimumChunkSize))
        let size = (count + desired - 1) / desired
        return stride(from: 0, to: count, by: size).map { $0..<min(count, $0 + size) }
    }
}
