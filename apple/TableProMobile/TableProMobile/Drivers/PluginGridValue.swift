import Foundation
import TableProModels

// A value as the grid reads it from a plugin that hands each value over while its row is read (DuckDB, SQLite).
nonisolated enum PluginGridValue: Sendable, Equatable {
    case null
    case text(String)
    // Long text the text budget took whole.
    case admitted(String)
    case cut(prefix: String, totalBytes: Int)
    case bytes(count: Int)
}

// Long text is copied only up to its preview and a BLOB only counted, so no value is held whole that the grid shows
// cut. A key column stays whole, since a long value is read back by it. Without a key a long value the budget admits
// stays whole too, as `Cell.from(text:options:ref:)` keeps it.
nonisolated struct PluginGridCut: Sendable {
    private let keys: Set<String>
    private let limit: Int
    private let budget: TextBudget?

    init(options: StreamOptions) {
        keys = Set(options.lazyContext?.primaryKeyColumns ?? [])
        limit = options.textTruncationBytes
        budget = options.lazyContext == nil ? options.textBudget : nil
    }

    func text(_ utf8: UnsafeRawBufferPointer, column: String) -> PluginGridValue {
        guard utf8.count > limit, !keys.contains(column) else { return .text(String(decoding: utf8, as: UTF8.self)) }
        if let budget, budget.admit(utf8.count) { return .admitted(String(decoding: utf8, as: UTF8.self)) }
        return .cut(prefix: Self.preview(of: utf8, maxBytes: limit), totalBytes: utf8.count)
    }

    // Decodes a little past the limit, at a scalar boundary, so the last Character the preview keeps is whole.
    static func preview(of utf8: UnsafeRawBufferPointer, maxBytes: Int) -> String {
        var end = min(utf8.count, maxBytes + 64)
        while end > 0, end < utf8.count, utf8[end] & 0xC0 == 0x80 {
            end -= 1
        }
        return Cell.preview(of: String(decoding: UnsafeRawBufferPointer(rebasing: utf8[..<end]), as: UTF8.self), maxBytes: maxBytes)
    }
}

// The rows of one grid read into its stream, under the read's cap. The plugin calls it from the read, one call at a
// time, so the lock only orders those calls with the stream's own thread.
nonisolated final class PluginGridSink: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<StreamElement, Error>.Continuation
    private let lock = NSLock()
    private var rows: PluginRowEmitter

    init(options: StreamOptions, continuation: AsyncThrowingStream<StreamElement, Error>.Continuation) {
        rows = PluginRowEmitter(options: options)
        self.continuation = continuation
    }

    func begin(columns: [String], typeNames: [String]) {
        lock.withLock { rows.begin(columns: columns, typeNames: typeNames, into: continuation) }
    }

    // False once a row past the cap arrived.
    func emit(_ batch: [[PluginGridValue]]) -> Bool {
        lock.withLock {
            for row in batch {
                let cells = Self.cells(of: row, rows: rows)
                guard rows.emit(cells: cells, locator: nil, into: continuation) else { return false }
            }
            return true
        }
    }

    private static func cells(of row: [PluginGridValue], rows: PluginRowEmitter) -> [Cell] {
        let keyText: (Int) -> String? = { index in
            guard index < row.count, case .text(let value) = row[index] else { return nil }
            return value
        }
        return row.indices.map { index -> Cell in
            let ref = rows.ref(column: rows.column(at: index), keyText: keyText, locator: nil)
            switch row[index] {
            case .null:
                return .null
            case .text(let text):
                return Cell.from(text: text, options: rows.options, ref: ref)
            case .admitted(let text):
                return .text(text)
            case .cut(let prefix, let totalBytes):
                return .truncatedText(prefix: prefix, totalBytes: totalBytes, ref: ref)
            case .bytes(let count):
                return .binary(byteCount: count, ref: ref)
            }
        }
    }
}
