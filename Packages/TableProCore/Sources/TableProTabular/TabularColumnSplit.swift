import Foundation
import TableProTabularIO

public enum TabularSplitSeparator {
    case literal(String)
    case regularExpression(NSRegularExpression)

    public func pieces(of text: String) -> [String] {
        switch self {
        case .literal(let separator):
            guard !separator.isEmpty else { return [text] }
            return text.components(separatedBy: separator)
        case .regularExpression(let expression):
            guard let matches = TabularRegex.matches(expression, in: text) else { return [text] }
            let source = text as NSString
            var pieces: [String] = []
            var location = 0
            for match in matches where match.range.length > 0 {
                pieces.append(source.substring(with: NSRange(location: location, length: match.range.location - location)))
                location = match.range.location + match.range.length
            }
            pieces.append(source.substring(from: location))
            return pieces
        }
    }
}

extension TabularSplitSeparator: @unchecked Sendable {}

public enum TabularColumnSplit {
    public static func split(
        column: TabularColumnID,
        by separator: TabularSplitSeparator,
        in table: TabularTable,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [ColumnValues] {
        let keys = table.rowOrder.keys
        let chunks = try await TabularScanEngine.forEachChunk(of: 0..<keys.count, progress: progress) { chunk, counter in
            var entries: [(key: Int, pieces: [String])] = []
            var processed = 0
            var cancelled = false
            table.scan(columns: [column], keys: keys[chunk]) { key, cells in
                let text = cells.string(at: 0)
                entries.append((key, cells.kinds[0].isNullLike ? [""] : separator.pieces(of: text)))
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
            return entries
        }
        var entries = chunks.flatMap { $0 }
        entries.sort { $0.key < $1.key }
        let pieceCount = max(1, entries.map(\.pieces.count).max() ?? 1)
        var result: [ColumnValues] = []
        result.reserveCapacity(pieceCount)
        for piece in 0..<pieceCount {
            var store = TabularValueStore()
            for entry in entries {
                store.append(piece < entry.pieces.count ? entry.pieces[piece] : "", kind: .text)
            }
            let patch = ColumnPatch(sortedKeys: entries.map(\.key), values: store)
            result.append(ColumnValues(base: .constant(table.source.absentCell), patch: patch))
        }
        return result
    }

    public static func merge(
        _ left: TabularColumnID,
        with right: TabularColumnID,
        separator: String,
        in table: TabularTable,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ColumnValues {
        let keys = table.rowOrder.keys
        let chunks = try await TabularScanEngine.forEachChunk(of: 0..<keys.count, progress: progress) { chunk, counter in
            var entries: [(key: Int, text: String)] = []
            var processed = 0
            var cancelled = false
            table.scan(columns: [left, right], keys: keys[chunk]) { key, cells in
                let first = cells.string(at: 0)
                let second = cells.string(at: 1)
                let merged = first.isEmpty || second.isEmpty ? first + second : first + separator + second
                entries.append((key, merged))
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
            return entries
        }
        var entries = chunks.flatMap { $0 }
        entries.sort { $0.key < $1.key }
        var store = TabularValueStore()
        for entry in entries {
            store.append(entry.text, kind: .text)
        }
        return ColumnValues(
            base: .constant(table.source.absentCell),
            patch: ColumnPatch(sortedKeys: entries.map(\.key), values: store)
        )
    }
}
