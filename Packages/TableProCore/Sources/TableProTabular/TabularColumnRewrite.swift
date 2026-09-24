import Foundation
import TableProTabularIO

public struct TabularRewriteResult: Sendable, Equatable {
    public let values: ColumnValues
    public let changedCells: Int
}

public enum TabularColumnRewrite {
    public typealias Transform = @Sendable (TabularCellKind, UnsafeBufferPointer<UInt8>) -> TabularCell?

    public static func rewrite(
        column: TabularColumnID,
        rows: [Int],
        in table: TabularTable,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        transform: @escaping Transform
    ) async throws -> TabularRewriteResult {
        guard let current = table.column(column) else {
            throw TabularEditError.unknownColumn
        }
        let edits = current.values.edits
        let chunks = try await TabularScanEngine.forEachChunk(of: 0..<rows.count, progress: progress) { chunk, counter in
            var changes: [(key: Int, cell: TabularCell)] = []
            var changed = 0
            var processed = 0
            var cancelled = false
            table.scan(columns: [column], logicalRows: rows[chunk]) { logicalRow, cells in
                let key = table.key(atRow: logicalRow)
                if let replacement = transform(cells.kinds[0], cells.bytes[0]) {
                    changes.append((key, replacement))
                    changed += 1
                } else if edits[key] != nil {
                    changes.append((key, TabularCell(kind: cells.kinds[0], text: cells.string(at: 0))))
                }
                processed += 1
                if processed == TabularScanEngine.cancellationStride {
                    counter.add(processed)
                    processed = 0
                    if Task.isCancelled {
                        cancelled = true
                        return false
                    }
                }
                return true
            }
            counter.add(processed)
            if cancelled { throw CancellationError() }
            return (changes, changed)
        }
        var entries = chunks.flatMap(\.0)
        let changedCells = chunks.reduce(0) { $0 + $1.1 }
        entries.sort { $0.key < $1.key }
        var store = TabularValueStore()
        store.reserve(values: entries.count, bytes: entries.reduce(0) { $0 + $1.cell.text.utf8.count })
        for entry in entries {
            store.append(entry.cell.text, kind: entry.cell.kind)
        }
        let patch = ColumnPatch(sortedKeys: entries.map(\.key), values: store)
        var values = current.values
        let rewrittenKeys = Set(entries.map(\.key))
        values.edits = values.edits.filter { !rewrittenKeys.contains($0.key) }
        values.patch = patch.merged(over: values.patch)
        return TabularRewriteResult(values: values, changedCells: changedCells)
    }

    public static func constantValues(_ cell: TabularCell) -> ColumnValues {
        ColumnValues(base: .constant(cell))
    }
}

public enum TabularEditError: Error, Equatable, Sendable {
    case unknownColumn
    case invalidPattern(String)
}
