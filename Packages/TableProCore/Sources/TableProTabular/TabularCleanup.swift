import CryptoKit
import Foundation
import TableProTabularIO

public enum TabularCaseStyle: String, Sendable, CaseIterable, Equatable {
    case uppercase
    case lowercase
    case titleCase
}

public enum TabularCleanupOperation: Sendable, Equatable {
    case trimWhitespace
    case changeCase(TabularCaseStyle)
    case setValue(String)
    case fillDown
}

public struct TabularCleanupResult: Sendable, Equatable {
    public let values: [TabularColumnID: ColumnValues]
    public let changedCells: Int
}

public enum TabularCleanup {
    public static func apply(
        _ operation: TabularCleanupOperation,
        columns: [TabularColumnID],
        keys: [Int],
        in table: TabularTable,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TabularCleanupResult {
        var values: [TabularColumnID: ColumnValues] = [:]
        var changed = 0
        let share = 1 / Double(max(1, columns.count))
        for (index, column) in columns.enumerated() {
            let columnProgress: @Sendable (Double) -> Void = { progress(Double(index) * share + $0 * share) }
            if case .setValue(let text) = operation, keys.count == table.rowCount, table.column(column) != nil {
                values[column] = ColumnValues(base: .constant(.text(text)))
                changed += try await countDiffering(column: column, from: text, keys: keys, table: table, progress: columnProgress)
                continue
            }
            let result: TabularRewriteResult
            switch operation {
            case .fillDown:
                guard let first = keys.first else { continue }
                let fill = table.cell(key: first, column: table.column(column) ?? TabularColumn(
                    id: column,
                    name: "",
                    values: ColumnValues(base: .constant(table.source.absentCell))
                ))
                result = try await TabularColumnRewrite.rewrite(
                    column: column,
                    keys: Array(keys.dropFirst()),
                    in: table,
                    progress: columnProgress
                ) { kind, bytes in
                    kind == fill.kind && TabularTextMatching.string(bytes) == fill.text ? nil : fill
                }
            case .setValue(let text):
                result = try await TabularColumnRewrite.rewrite(column: column, keys: keys, in: table, progress: columnProgress) { _, bytes in
                    TabularTextMatching.string(bytes) == text ? nil : .text(text)
                }
            case .trimWhitespace, .changeCase:
                result = try await TabularColumnRewrite.rewrite(column: column, keys: keys, in: table, progress: columnProgress) { kind, bytes in
                    guard !kind.isNullLike, !bytes.isEmpty else { return nil }
                    let original = TabularTextMatching.string(bytes)
                    let transformed = transform(original, operation)
                    return transformed == original ? nil : TabularCell(kind: kind == .text ? .text : kind, text: transformed)
                }
            }
            guard result.changedCells > 0 else { continue }
            values[column] = result.values
            changed += result.changedCells
        }
        return TabularCleanupResult(values: values, changedCells: changed)
    }

    public static func transform(_ text: String, _ operation: TabularCleanupOperation) -> String {
        switch operation {
        case .trimWhitespace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .changeCase(.uppercase):
            return text.uppercased()
        case .changeCase(.lowercase):
            return text.lowercased()
        case .changeCase(.titleCase):
            return text.capitalized
        case .setValue(let value):
            return value
        case .fillDown:
            return text
        }
    }

    private static func countDiffering(
        column: TabularColumnID,
        from text: String,
        keys: [Int],
        table: TabularTable,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        let needle = Array(text.utf8)
        let counts = try await TabularScanEngine.forEachChunk(of: 0..<keys.count, progress: progress) { chunk, counter in
            var differing = 0
            var processed = 0
            var cancelled = false
            table.scan(columns: [column], keys: keys[chunk]) { _, cells in
                if !cells.bytes[0].elementsEqual(needle) || cells.kinds[0].isNullLike {
                    differing += 1
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
            return differing
        }
        return counts.reduce(0, +)
    }
}

public struct TabularDuplicateOptions: Sendable, Equatable {
    public var ignoresCase: Bool
    public var ignoresSurroundingWhitespace: Bool

    public init(ignoresCase: Bool = false, ignoresSurroundingWhitespace: Bool = false) {
        self.ignoresCase = ignoresCase
        self.ignoresSurroundingWhitespace = ignoresSurroundingWhitespace
    }
}

public enum TabularDuplicates {
    public static func duplicateKeys(
        comparing columns: [TabularColumnID],
        keys rows: [Int],
        in table: TabularTable,
        options: TabularDuplicateOptions = TabularDuplicateOptions(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Int] {
        guard !columns.isEmpty, rows.count > 1 else { return [] }
        let chunks = try await TabularScanEngine.forEachChunk(of: 0..<rows.count, progress: { progress($0 * 0.9) }) { chunk, counter in
            var keys: [RowFingerprint] = []
            keys.reserveCapacity(chunk.count)
            var processed = 0
            var cancelled = false
            table.scan(columns: columns, keys: rows[chunk]) { _, cells in
                keys.append(RowFingerprint(cells, options: options))
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
            return keys
        }
        var seen = Set<RowFingerprint>()
        seen.reserveCapacity(rows.count)
        var duplicates: [Int] = []
        var position = 0
        for chunk in chunks {
            for key in chunk {
                if !seen.insert(key).inserted {
                    duplicates.append(rows[position])
                }
                position += 1
            }
        }
        progress(1)
        return duplicates
    }
}

struct RowFingerprint: Hashable, Sendable {
    let first: UInt64
    let second: UInt64

    init(_ cells: TabularRowCells, options: TabularDuplicateOptions) {
        var hasher = SHA256()
        for index in 0..<cells.count {
            let normalized = Self.normalized(cells.bytes[index], kind: cells.kinds[index], options: options)
            var length = UInt64(normalized.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            normalized.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        var first: UInt64 = 0
        var second: UInt64 = 0
        hasher.finalize().withUnsafeBytes { digest in
            first = digest.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            second = digest.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        }
        self.first = first
        self.second = second
    }

    private static func normalized(
        _ bytes: UnsafeBufferPointer<UInt8>,
        kind: TabularCellKind,
        options: TabularDuplicateOptions
    ) -> [UInt8] {
        guard !kind.isNullLike else { return [0xFF, kind.rawValue] }
        guard options.ignoresCase || options.ignoresSurroundingWhitespace else { return Array(bytes) }
        var text = TabularTextCodec.utf8String(bytes)
        if options.ignoresSurroundingWhitespace {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if options.ignoresCase {
            text = text.lowercased()
        }
        return Array(text.utf8)
    }
}
