import Foundation

public struct JSONTableWriter {
    private static let flushThreshold = 1 << 20
    private static let bufferSlack = 1 << 16

    public let shape: JSONTableShape
    public let source: JSONSource?
    public let keyChanges: [String: JSONMemberChange]

    public init(source: JSONSource, keyChanges: [String: JSONMemberChange] = [:]) {
        self.source = source
        self.keyChanges = keyChanges
        shape = source.shape
    }

    public init(shape: JSONTableShape) {
        self.shape = shape
        source = nil
        keyChanges = [:]
    }

    public func write<Rows: Sequence>(
        to url: URL,
        rows: Rows,
        isCancelled: () -> Bool = { false }
    ) throws where Rows.Element == JSONOutputRow {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TabularWriteError.couldNotCreate(path: url.path)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw TabularWriteError.writeFailed(message: error.localizedDescription)
        }
        defer { try? handle.close() }
        try emit(rows: rows, isCancelled: isCancelled) { chunk in
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                throw TabularWriteError.writeFailed(message: error.localizedDescription)
            }
        }
    }

    public func encoded<Rows: Sequence>(rows: Rows) throws -> [UInt8] where Rows.Element == JSONOutputRow {
        var result: [UInt8] = []
        try emit(rows: rows, isCancelled: { false }) { result.append(contentsOf: $0) }
        return result
    }

    private func emit<Rows: Sequence>(
        rows: Rows,
        isCancelled: () -> Bool,
        sink: ([UInt8]) throws -> Void
    ) throws where Rows.Element == JSONOutputRow {
        let rules = JSONLiteralRules(forbidsLineBreaks: shape == .lines)
        let columnPlans = try resolvedColumnPlans(rules: rules)
        let keyTable = source?.index.keyTable ?? JSONKeyTable()
        let data = source?.bytes ?? Data()
        try data.withUnsafeBytes { raw in
            try keyTable.withLookup { keys in
                var emitter = JSONDocumentEmitter(
                    bytes: raw.bindMemory(to: UInt8.self),
                    index: source?.index,
                    shape: shape,
                    splicer: JSONObjectSplicer(keys: keys, columnPlans: columnPlans, rules: rules),
                    rules: rules,
                    capacity: min(raw.count, Self.flushThreshold) + Self.bufferSlack
                )
                for row in rows {
                    try emitter.append(row)
                    guard emitter.output.count >= Self.flushThreshold else { continue }
                    if isCancelled() { throw TabularCancellation() }
                    try sink(emitter.output)
                    emitter.output.removeAll(keepingCapacity: true)
                }
                try emitter.finish()
                try sink(emitter.output)
            }
        }
    }

    private func resolvedColumnPlans(rules: JSONLiteralRules) throws -> [JSONColumnPlan?] {
        guard let source, !keyChanges.isEmpty else { return [] }
        let keyTable = source.index.keyTable
        var changes = [JSONMemberChange?](repeating: nil, count: source.columnCount)
        for (key, change) in keyChanges {
            guard let column = keyTable.column(named: key) else { continue }
            if let literal = change.newLiteral {
                try rules.check(literal)
            }
            changes[column] = change
        }
        var names = Set<String>()
        for (column, name) in source.keys.enumerated() where changes[column] != .remove {
            let finalName = changes[column]?.newKey ?? name
            guard names.insert(finalName).inserted else { throw JSONTableWriteError.duplicateKey(finalName) }
        }
        return changes.map { $0.map(JSONColumnPlan.init) }
    }
}

private struct JSONDocumentEmitter {
    private enum PendingRow {
        case source(Int)
        case splice(Int, JSONObjectEdit?)
        case new([JSONNewMember])

        var sourceRow: Int? {
            switch self {
            case .source(let row), .splice(let row, _):
                return row
            case .new:
                return nil
            }
        }
    }

    private static let sourcelessArrayPrefix = Array("[\n".utf8)
    private static let sourcelessArraySeparator = Array(",\n".utf8)
    private static let sourcelessArraySuffix = Array("\n]\n".utf8)
    private static let sourcelessEmptyArray = Array("[]\n".utf8)

    let bytes: UnsafeBufferPointer<UInt8>
    let index: JSONTableIndex?
    let shape: JSONTableShape
    let rules: JSONLiteralRules
    var output: [UInt8] = []
    private let lineEnding: [UInt8]
    private var splicer: JSONObjectSplicer
    private var pending: PendingRow?
    private var arraySeparator: [UInt8]?

    init(
        bytes: UnsafeBufferPointer<UInt8>,
        index: JSONTableIndex?,
        shape: JSONTableShape,
        splicer: JSONObjectSplicer,
        rules: JSONLiteralRules,
        capacity: Int
    ) {
        self.bytes = bytes
        self.index = index
        self.shape = shape
        self.splicer = splicer
        self.rules = rules
        lineEnding = (index?.lineEnding ?? .lf).bytes
        output.reserveCapacity(capacity)
    }

    mutating func append(_ row: JSONOutputRow) throws {
        let next = try pendingRow(for: row)
        if let previous = pending {
            try emit(previous, before: next.sourceRow)
        } else {
            emitPrefix()
        }
        pending = next
    }

    mutating func finish() throws {
        guard let last = pending else {
            emitEmptyDocument()
            return
        }
        _ = try emitObject(last)
        try emitSuffix()
    }

    private func pendingRow(for row: JSONOutputRow) throws -> PendingRow {
        switch row {
        case .source(let sourceRow):
            try requireSourceRow(sourceRow)
            return splicer.hasColumnPlans ? .splice(sourceRow, nil) : .source(sourceRow)
        case .edited(let sourceRow, let edit):
            try requireSourceRow(sourceRow)
            return .splice(sourceRow, edit)
        case .new(let members):
            return .new(members)
        }
    }

    private func requireSourceRow(_ row: Int) throws {
        guard let index, row >= 0, row < index.rowCount, bytes.baseAddress != nil else {
            throw JSONTableWriteError.sourceRowUnavailable(row)
        }
    }

    private mutating func emit(_ previous: PendingRow, before nextRow: Int?) throws {
        if case .source(let row) = previous, nextRow == row + 1, let index {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[index.rowStarts[row]..<index.rowStarts[row + 1]]))
            return
        }
        let end = try emitObject(previous)
        try appendSeparator(after: previous.sourceRow, end: end, before: nextRow)
    }

    private mutating func emitObject(_ row: PendingRow) throws -> Int? {
        switch row {
        case .new(let members):
            try JSONObjectSplicer.appendNewObject(members, rules: rules, into: &output)
            return nil
        case .source(let sourceRow):
            let start = try rowStart(sourceRow)
            let end = try objectEnd(ofRow: sourceRow)
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<end]))
            return end
        case .splice(let sourceRow, let edit):
            guard let base = bytes.baseAddress else { throw JSONTableWriteError.sourceRowUnavailable(sourceRow) }
            let cursor = JSONCursor(base: base, count: bytes.count, row: sourceRow)
            return try splicer.splice(cursor, objectAt: try rowStart(sourceRow), edit: edit, into: &output)
        }
    }

    private mutating func appendSeparator(after previousRow: Int?, end: Int?, before nextRow: Int?) throws {
        guard let index else {
            output.append(contentsOf: shape == .array ? Self.sourcelessArraySeparator : lineEnding)
            return
        }
        if let previousRow, let end {
            let trailing = end..<(previousRow + 1 < index.rowCount ? index.rowStarts[previousRow + 1] : index.endOffset)
            let keepsTrailing = nextRow == previousRow + 1
                || (shape == .lines && bytes[trailing].contains(where: JSONByte.isLineBreak))
            if keepsTrailing {
                output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[trailing]))
                return
            }
        }
        guard shape == .array else {
            output.append(contentsOf: lineEnding)
            return
        }
        output.append(contentsOf: try styleSeparator(for: index))
    }

    private mutating func styleSeparator(for index: JSONTableIndex) throws -> [UInt8] {
        if let arraySeparator { return arraySeparator }
        let resolved: [UInt8]
        if index.rowCount >= 2 {
            resolved = Array(UnsafeBufferPointer(rebasing: bytes[try objectEnd(ofRow: 0)..<index.rowStarts[1]]))
        } else if index.rowCount == 1, let opening = index.openingBracket {
            resolved = [JSONByte.comma] + Array(UnsafeBufferPointer(rebasing: bytes[(opening + 1)..<index.rowStarts[0]]))
        } else {
            resolved = [JSONByte.comma]
        }
        arraySeparator = resolved
        return resolved
    }

    private mutating func emitPrefix() {
        guard let index else {
            if shape == .array {
                output.append(contentsOf: Self.sourcelessArrayPrefix)
            }
            return
        }
        if let first = index.rowStarts.first {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0..<first]))
        } else if let opening = index.openingBracket {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0...opening]))
        } else {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0..<index.contentStart]))
        }
    }

    private mutating func emitSuffix() throws {
        guard let index else {
            output.append(contentsOf: shape == .array ? Self.sourcelessArraySuffix : lineEnding)
            return
        }
        guard index.rowCount > 0 else {
            if index.openingBracket == nil {
                output.append(contentsOf: lineEnding)
            } else {
                output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[index.bodyEnd..<index.endOffset]))
            }
            return
        }
        let end = try objectEnd(ofRow: index.rowCount - 1)
        output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[end..<index.endOffset]))
    }

    private mutating func emitEmptyDocument() {
        guard let index else {
            if shape == .array {
                output.append(contentsOf: Self.sourcelessEmptyArray)
            }
            return
        }
        guard index.rowCount > 0 else {
            output.append(contentsOf: bytes)
            return
        }
        guard let opening = index.openingBracket else {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0..<index.contentStart]))
            return
        }
        output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0...opening]))
        output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[index.bodyEnd..<index.endOffset]))
    }

    private func rowStart(_ row: Int) throws -> Int {
        guard let index else { throw JSONTableWriteError.sourceRowUnavailable(row) }
        return index.rowStarts[row]
    }

    private func objectEnd(ofRow row: Int) throws -> Int {
        try JSONRowParser.objectEnd(in: bytes, at: try rowStart(row), row: row)
    }
}
