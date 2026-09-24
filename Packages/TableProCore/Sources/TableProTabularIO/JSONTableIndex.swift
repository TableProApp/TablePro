import Foundation

public enum JSONTableFileKind: Sendable, Equatable {
    case json
    case jsonLines

    public static func forFileExtension(_ fileExtension: String) -> JSONTableFileKind {
        switch fileExtension.lowercased() {
        case "jsonl", "ndjson", "jsonlines":
            return .jsonLines
        default:
            return .json
        }
    }
}

public enum JSONTableShape: Sendable, Equatable {
    case array
    case lines
}

public struct JSONTableIndex: Sendable {
    public let shape: JSONTableShape
    public let rowStarts: [Int]
    public let contentStart: Int
    public let openingBracket: Int?
    public let bodyEnd: Int
    public let endOffset: Int
    public let lineEnding: DelimitedDialect.LineEnding
    public let keyTable: JSONKeyTable

    public init(
        shape: JSONTableShape,
        rowStarts: [Int],
        contentStart: Int,
        openingBracket: Int?,
        bodyEnd: Int,
        endOffset: Int,
        lineEnding: DelimitedDialect.LineEnding,
        keyTable: JSONKeyTable
    ) {
        self.shape = shape
        self.rowStarts = rowStarts
        self.contentStart = contentStart
        self.openingBracket = openingBracket
        self.bodyEnd = bodyEnd
        self.endOffset = endOffset
        self.lineEnding = lineEnding
        self.keyTable = keyTable
    }

    public var rowCount: Int { rowStarts.count }

    public var keys: [String] { keyTable.names }

    public var hasByteOrderMark: Bool { contentStart > 0 }

    public func span(ofRow row: Int) -> Range<Int> {
        let start = rowStarts[row]
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] : bodyEnd
        return start..<end
    }
}

public enum JSONTableIndexer {
    public static func index(
        _ bytes: UnsafeBufferPointer<UInt8>,
        fileKind: JSONTableFileKind,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> JSONTableIndex {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            guard fileKind == .jsonLines else { throw JSONTableError.emptyDocument }
            return emptyLinesIndex(contentStart: 0, endOffset: 0, lineEnding: .lf)
        }
        return try withoutActuallyEscaping(isCancelled) { cancelled in
            var scanner = JSONStructureScanner(base: base, count: bytes.count, progress: progress, isCancelled: cancelled)
            let index = try scanner.scanDocument(fileKind: fileKind)
            progress?(1)
            return index
        }
    }

    internal static func emptyLinesIndex(
        contentStart: Int,
        endOffset: Int,
        lineEnding: DelimitedDialect.LineEnding
    ) -> JSONTableIndex {
        JSONTableIndex(
            shape: .lines,
            rowStarts: [],
            contentStart: contentStart,
            openingBracket: nil,
            bodyEnd: endOffset,
            endOffset: endOffset,
            lineEnding: lineEnding,
            keyTable: JSONKeyTable()
        )
    }
}

private struct JSONStructureScanner {
    private static let progressStride = 1 << 24

    let base: UnsafePointer<UInt8>
    let count: Int
    let progress: ((Double) -> Void)?
    let isCancelled: () -> Bool
    private var keyTable = JSONKeyTable()
    private var predictor = JSONKeyPredictor()
    private var stack = JSONBracketStack()
    private var block = JSONBlockCursor()
    private var decodedKey: [UInt8] = []
    private var padded = [UInt8](repeating: JSONByte.space, count: JSONBlockMasks.width)
    private var rowStarts: [Int] = []
    private var lineEnding: DelimitedDialect.LineEnding?
    private var segmentEnd: Int

    init(
        base: UnsafePointer<UInt8>,
        count: Int,
        progress: ((Double) -> Void)?,
        isCancelled: @escaping () -> Bool
    ) {
        self.base = base
        self.count = count
        self.progress = progress
        self.isCancelled = isCancelled
        segmentEnd = min(count, Self.progressStride)
        rowStarts.reserveCapacity(max(16, count / 96))
    }

    mutating func scanDocument(fileKind: JSONTableFileKind) throws -> JSONTableIndex {
        if JSONByte.utf16ByteOrderMarks.contains(where: hasPrefix) {
            throw JSONTableError.unsupportedEncoding
        }
        let contentStart = hasPrefix(JSONByte.utf8ByteOrderMark) ? JSONByte.utf8ByteOrderMark.count : 0
        let first = try skipWhitespace(from: contentStart)
        guard first < count else {
            guard fileKind == .jsonLines else { throw JSONTableError.emptyDocument }
            return JSONTableIndexer.emptyLinesIndex(
                contentStart: contentStart,
                endOffset: count,
                lineEnding: lineEnding ?? .lf
            )
        }
        switch base[first] {
        case JSONByte.openBracket:
            return try scanArray(openingAt: first, contentStart: contentStart)
        case JSONByte.openBrace:
            return try scanLines(firstRowAt: first, contentStart: contentStart, fileKind: fileKind)
        default:
            guard fileKind == .jsonLines else {
                guard JSONByte.startsValue(base[first]) else {
                    throw JSONTableError.unexpectedByte(row: 0, byteOffset: first)
                }
                throw JSONTableError.scalarDocument(byteOffset: first)
            }
            throw notAnObject(row: 0, at: first)
        }
    }

    private mutating func scanArray(openingAt opening: Int, contentStart: Int) throws -> JSONTableIndex {
        var index = try skipWhitespace(from: opening + 1)
        guard index < count else { throw JSONTableError.truncated(row: 0, byteOffset: count) }
        var closing = index
        if base[index] != JSONByte.closeBracket {
            while true {
                let row = rowStarts.count
                guard index < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
                guard base[index] == JSONByte.openBrace else { throw notAnObject(row: row, at: index) }
                rowStarts.append(index)
                index = try skipWhitespace(from: try scanObject(at: index, row: row))
                guard index < count else { throw JSONTableError.truncated(row: row + 1, byteOffset: count) }
                if base[index] == JSONByte.closeBracket {
                    closing = index
                    break
                }
                guard base[index] == JSONByte.comma else {
                    throw JSONTableError.unexpectedByte(row: row + 1, byteOffset: index)
                }
                index = try skipWhitespace(from: index + 1)
            }
        }
        let trailing = try skipWhitespace(from: closing + 1)
        guard trailing == count else {
            throw JSONTableError.trailingContent(row: rowStarts.count, byteOffset: trailing)
        }
        return JSONTableIndex(
            shape: .array,
            rowStarts: rowStarts,
            contentStart: contentStart,
            openingBracket: opening,
            bodyEnd: closing,
            endOffset: count,
            lineEnding: lineEnding ?? .lf,
            keyTable: keyTable
        )
    }

    private mutating func scanLines(
        firstRowAt first: Int,
        contentStart: Int,
        fileKind: JSONTableFileKind
    ) throws -> JSONTableIndex {
        var index = first
        while index < count {
            let row = rowStarts.count
            guard base[index] == JSONByte.openBrace else { throw notAnObject(row: row, at: index) }
            rowStarts.append(index)
            index = try skipWhitespace(from: try scanObject(at: index, row: row))
        }
        if fileKind == .json, rowStarts.count == 1 {
            throw JSONTableError.singleObject(byteOffset: first)
        }
        return JSONTableIndex(
            shape: .lines,
            rowStarts: rowStarts,
            contentStart: contentStart,
            openingBracket: nil,
            bodyEnd: count,
            endOffset: count,
            lineEnding: lineEnding ?? .lf,
            keyTable: keyTable
        )
    }

    private mutating func scanObject(at start: Int, row: Int) throws -> Int {
        stack.reset()
        positionBlock(at: start)
        var ordinal = 0
        while true {
            while block.events != 0 {
                let bit = block.events.trailingZeroBitCount
                block.events &= block.events &- 1
                let position = block.start + bit
                let byte = base[position]
                if byte == JSONByte.colon {
                    guard stack.depth == 1 else { continue }
                    registerKey(block.keyQuotes(before: bit), rowStart: start, ordinal: ordinal)
                    ordinal += 1
                    continue
                }
                if byte == JSONByte.openBrace || byte == JSONByte.openBracket {
                    stack.push(isArray: byte == JSONByte.openBracket)
                    continue
                }
                guard stack.depth > 0, stack.pop() == (byte == JSONByte.closeBracket) else {
                    throw JSONTableError.mismatchedBracket(row: row, byteOffset: position)
                }
                if stack.depth == 0 { return position + 1 }
            }
            let next = block.start + JSONBlockMasks.width
            guard next < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
            if next >= segmentEnd {
                try checkpoint(at: next)
            }
            block.advance(to: blockMasks(at: next), at: next)
        }
    }

    private mutating func positionBlock(at start: Int) {
        if block.contains(start) {
            block.discardEvents(before: start)
            return
        }
        block = JSONBlockCursor(masks: blockMasks(at: start), at: start)
    }

    private mutating func blockMasks(at blockStart: Int) -> JSONBlockMasks {
        guard blockStart + JSONBlockMasks.width > count else { return JSONBlockMasks(base + blockStart) }
        let remaining = count - blockStart
        for offset in 0..<JSONBlockMasks.width {
            padded[offset] = offset < remaining ? base[blockStart + offset] : JSONByte.space
        }
        return padded.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map(JSONBlockMasks.init) ?? JSONBlockMasks.empty
        }
    }

    private mutating func registerKey(_ quotes: (opening: Int, closing: Int), rowStart: Int, ordinal: Int) {
        guard quotes.opening > rowStart, quotes.closing > quotes.opening else { return }
        let key = UnsafeBufferPointer(start: base + quotes.opening + 1, count: quotes.closing - quotes.opening - 1)
        let hasEscapes = block.contains(quotes.opening)
            ? block.hasBackslash(between: quotes.opening, and: quotes.closing)
            : key.contains(JSONByte.backslash)
        guard hasEscapes else {
            predictor.register(key, ordinal: ordinal, in: &keyTable)
            return
        }
        var scratch = decodedKey
        decodedKey = []
        scratch.removeAll(keepingCapacity: true)
        JSONText.appendDecoded(key, into: &scratch)
        scratch.withUnsafeBufferPointer { predictor.register($0, ordinal: ordinal, in: &keyTable) }
        decodedKey = scratch
    }

    private mutating func skipWhitespace(from start: Int) throws -> Int {
        var index = start
        while index < count {
            if index >= segmentEnd {
                try checkpoint(at: index)
            }
            let byte = base[index]
            guard JSONByte.isWhitespace(byte) else { return index }
            if lineEnding == nil, JSONByte.isLineBreak(byte) {
                lineEnding = lineEndingStarting(at: index)
            }
            index += 1
        }
        return index
    }

    private func lineEndingStarting(at index: Int) -> DelimitedDialect.LineEnding {
        guard base[index] == JSONByte.carriageReturn else { return .lf }
        return index + 1 < count && base[index + 1] == JSONByte.lineFeed ? .crlf : .cr
    }

    private mutating func checkpoint(at index: Int) throws {
        if isCancelled() { throw TabularCancellation() }
        progress?(Double(index) / Double(count))
        segmentEnd = min(count, index + Self.progressStride)
    }

    private func notAnObject(row: Int, at offset: Int) -> JSONTableError {
        guard JSONByte.startsValue(base[offset]) else {
            return .unexpectedByte(row: row, byteOffset: offset)
        }
        return .rowIsNotAnObject(row: row, byteOffset: offset)
    }

    private func hasPrefix(_ prefix: [UInt8]) -> Bool {
        guard count >= prefix.count else { return false }
        for (offset, byte) in prefix.enumerated() where base[offset] != byte {
            return false
        }
        return true
    }
}
