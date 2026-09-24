import Foundation

public struct JSONTableWriter {
    private static let flushThreshold = 1 << 20

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
        let columnChanges = try resolvedColumnChanges()
        let data = source?.bytes ?? Data()
        try data.withUnsafeBytes { raw in
            var emitter = JSONDocumentEmitter(
                bytes: raw.bindMemory(to: UInt8.self),
                index: source?.index,
                shape: shape,
                columnChanges: columnChanges
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

    private func resolvedColumnChanges() throws -> [JSONMemberChange?] {
        guard let source, !keyChanges.isEmpty else { return [] }
        let keyTable = source.index.keyTable
        var changes = [JSONMemberChange?](repeating: nil, count: source.columnCount)
        for (key, change) in keyChanges {
            guard let column = keyTable.column(named: key) else { continue }
            changes[column] = change
        }
        var names = Set<String>()
        for (column, name) in source.keys.enumerated() where changes[column] != .remove {
            let finalName = changes[column]?.newKey ?? name
            guard names.insert(finalName).inserted else { throw JSONTableWriteError.duplicateKey(finalName) }
        }
        return changes
    }
}

private struct JSONDocumentEmitter {
    private enum Content {
        case source
        case bytes([UInt8])
    }

    private struct RenderedRow {
        let sourceRow: Int?
        var sourceEnd: Int?
        let content: Content
    }

    private static let sourcelessArrayPrefix = Array("[\n".utf8)
    private static let sourcelessArraySeparator = Array(",\n".utf8)
    private static let sourcelessArraySuffix = Array("\n]\n".utf8)
    private static let sourcelessEmptyArray = Array("[]\n".utf8)

    let bytes: UnsafeBufferPointer<UInt8>
    let index: JSONTableIndex?
    let shape: JSONTableShape
    let columnChanges: [JSONMemberChange?]
    let rules: JSONLiteralRules
    var output: [UInt8] = []
    private var predictor = JSONKeyPredictor()
    private var pending: RenderedRow?
    private var arraySeparator: [UInt8]?

    init(bytes: UnsafeBufferPointer<UInt8>, index: JSONTableIndex?, shape: JSONTableShape, columnChanges: [JSONMemberChange?]) {
        self.bytes = bytes
        self.index = index
        self.shape = shape
        self.columnChanges = columnChanges
        rules = JSONLiteralRules(forbidsLineBreaks: shape == .lines)
        output.reserveCapacity(1 << 20 + 65_536)
    }

    private var hasColumnChanges: Bool {
        columnChanges.contains { $0 != nil }
    }

    mutating func append(_ row: JSONOutputRow) throws {
        let rendered = try render(row)
        if let previous = pending {
            try emit(previous, before: rendered)
        } else {
            emitPrefix()
        }
        pending = rendered
    }

    mutating func finish() throws {
        guard let last = pending else {
            emitEmptyDocument()
            return
        }
        _ = try emitObject(last)
        try emitSuffix()
    }

    private mutating func render(_ row: JSONOutputRow) throws -> RenderedRow {
        switch row {
        case .source(let sourceRow):
            try requireSourceRow(sourceRow)
            guard hasColumnChanges else { return RenderedRow(sourceRow: sourceRow, sourceEnd: nil, content: .source) }
            return try splice(sourceRow, edit: nil)
        case .edited(let sourceRow, let edit):
            try requireSourceRow(sourceRow)
            return try splice(sourceRow, edit: edit)
        case .new(let members):
            return RenderedRow(sourceRow: nil, sourceEnd: nil, content: .bytes(try JSONObjectSplicer.serialize(members, rules: rules)))
        }
    }

    private func requireSourceRow(_ row: Int) throws {
        guard let index, row >= 0, row < index.rowCount, bytes.baseAddress != nil else {
            throw JSONTableWriteError.sourceRowUnavailable(row)
        }
    }

    private mutating func splice(_ row: Int, edit: JSONObjectEdit?) throws -> RenderedRow {
        guard let index, let base = bytes.baseAddress else { throw JSONTableWriteError.sourceRowUnavailable(row) }
        let splicer = JSONObjectSplicer(
            cursor: JSONCursor(base: base, count: bytes.count, row: row),
            keyTable: index.keyTable,
            columnChanges: columnChanges,
            rules: rules
        )
        switch try splicer.splice(objectAt: index.rowStarts[row], edit: edit, predictor: &predictor) {
        case .unchanged(let end):
            return RenderedRow(sourceRow: row, sourceEnd: end, content: .source)
        case .rewritten(let rewritten, let end):
            return RenderedRow(sourceRow: row, sourceEnd: end, content: .bytes(rewritten))
        }
    }

    private mutating func emit(_ previous: RenderedRow, before next: RenderedRow) throws {
        if case .source = previous.content, let row = previous.sourceRow, next.sourceRow == row + 1, let index {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[index.rowStarts[row]..<index.rowStarts[row + 1]]))
            return
        }
        let end = try emitObject(previous)
        output.append(contentsOf: try separator(after: previous.sourceRow, end: end, before: next.sourceRow))
    }

    private mutating func emitObject(_ row: RenderedRow) throws -> Int? {
        switch row.content {
        case .bytes(let content):
            output.append(contentsOf: content)
            return row.sourceEnd
        case .source:
            guard let sourceRow = row.sourceRow, let index else { return nil }
            let end = try row.sourceEnd ?? objectEnd(ofRow: sourceRow)
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[index.rowStarts[sourceRow]..<end]))
            return end
        }
    }

    private mutating func separator(after previousRow: Int?, end: Int?, before nextRow: Int?) throws -> [UInt8] {
        guard let index else {
            return shape == .array ? Self.sourcelessArraySeparator : DelimitedDialect.LineEnding.lf.bytes
        }
        if let previousRow, let end {
            let trailing = end..<(previousRow + 1 < index.rowCount ? index.rowStarts[previousRow + 1] : index.endOffset)
            if nextRow == previousRow + 1 {
                return Array(UnsafeBufferPointer(rebasing: bytes[trailing]))
            }
            if shape == .lines, bytes[trailing].contains(where: JSONByte.isLineBreak) {
                return Array(UnsafeBufferPointer(rebasing: bytes[trailing]))
            }
        }
        guard shape == .array else { return index.lineEnding.bytes }
        return try styleSeparator(for: index)
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
            output.append(contentsOf: shape == .array ? Self.sourcelessArraySuffix : DelimitedDialect.LineEnding.lf.bytes)
            return
        }
        guard index.rowCount > 0 else {
            if index.openingBracket == nil {
                output.append(contentsOf: index.lineEnding.bytes)
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

    private func objectEnd(ofRow row: Int) throws -> Int {
        guard let index else { throw JSONTableWriteError.sourceRowUnavailable(row) }
        return try JSONRowParser.objectEnd(in: bytes, at: index.rowStarts[row], row: row)
    }
}
