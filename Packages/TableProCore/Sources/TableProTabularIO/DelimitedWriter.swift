import Foundation

public enum DelimitedOutputRow: Sendable, Equatable {
    case source(Int)
    case fields([String])
}

public enum TabularWriteError: Error, Equatable, Sendable {
    case unencodable(row: Int, column: Int, character: Character, encoding: TabularTextEncoding)
    case couldNotCreate(path: String)
    case writeFailed(message: String)
}

public struct DelimitedWriter {
    private static let flushThreshold = 1 << 20

    public let dialect: DelimitedDialect
    public let source: DelimitedSource?

    public init(dialect: DelimitedDialect, source: DelimitedSource?) {
        self.dialect = dialect
        self.source = source
    }

    public var canCopySourceBytes: Bool {
        guard let source else { return false }
        return source.byteEncoding == dialect.encoding
            && source.dialect.delimiter == dialect.delimiter
            && source.dialect.quote == dialect.quote
            && source.dialect.escape == dialect.escape
    }

    public func write<Rows: Sequence>(
        to url: URL,
        rows: Rows,
        endsWithLineTerminator: Bool,
        isCancelled: () -> Bool = { false }
    ) throws where Rows.Element == DelimitedOutputRow {
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
        var buffer: [UInt8] = []
        buffer.reserveCapacity(Self.flushThreshold + 65_536)
        if dialect.hasByteOrderMark {
            buffer.append(contentsOf: dialect.encoding.byteOrderMark)
        }
        let lineEnding = try encodedLineEnding()
        var pendingTerminator = false
        var outputRow = 0
        for row in rows {
            if pendingTerminator {
                buffer.append(contentsOf: lineEnding)
            }
            pendingTerminator = try append(row, outputRow: outputRow, lineEnding: lineEnding, into: &buffer)
            outputRow += 1
            if buffer.count >= Self.flushThreshold {
                if isCancelled() { throw TabularCancellation() }
                try flush(&buffer, to: handle)
            }
        }
        if pendingTerminator, endsWithLineTerminator {
            buffer.append(contentsOf: lineEnding)
        }
        try flush(&buffer, to: handle)
    }

    public func encodeRow(_ fields: [String], outputRow: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for (column, field) in fields.enumerated() {
            if column > 0 {
                bytes.append(contentsOf: try encode(String(UnicodeScalar(dialect.delimiter)), row: outputRow, column: column))
            }
            bytes.append(contentsOf: try encode(quoted(field), row: outputRow, column: column))
        }
        return bytes
    }

    public func quoted(_ field: String) -> String {
        let delimiter = UnicodeScalar(dialect.delimiter)
        let quote = UnicodeScalar(dialect.quote)
        let needsQuoting = field.unicodeScalars.contains { scalar in
            scalar == delimiter || scalar == quote || scalar == "\n" || scalar == "\r"
        }
        guard needsQuoting else { return field }
        let quoteText = String(quote)
        guard !dialect.escapesByDoubling else {
            return quoteText + field.replacingOccurrences(of: quoteText, with: quoteText + quoteText) + quoteText
        }
        let escapeText = String(UnicodeScalar(dialect.escape))
        let body = field
            .replacingOccurrences(of: escapeText, with: escapeText + escapeText)
            .replacingOccurrences(of: quoteText, with: escapeText + quoteText)
        return quoteText + body + quoteText
    }

    private func append(
        _ row: DelimitedOutputRow,
        outputRow: Int,
        lineEnding: [UInt8],
        into buffer: inout [UInt8]
    ) throws -> Bool {
        switch row {
        case .fields(let fields):
            buffer.append(contentsOf: try encodeRow(fields, outputRow: outputRow))
            return true
        case .source(let sourceRow):
            guard let source else { return false }
            return try appendSourceRow(sourceRow, of: source, outputRow: outputRow, lineEnding: lineEnding, into: &buffer)
        }
    }

    private func appendSourceRow(
        _ sourceRow: Int,
        of source: DelimitedSource,
        outputRow: Int,
        lineEnding: [UInt8],
        into buffer: inout [UInt8]
    ) throws -> Bool {
        guard canCopySourceBytes else {
            buffer.append(contentsOf: try encodeRow(source.decodedFields(row: sourceRow), outputRow: outputRow))
            return true
        }
        let range = source.rawRange(ofRow: sourceRow)
        let terminatorLength = source.bytes.withUnsafeBytes { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            buffer.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[range]))
            return Self.terminatorLength(in: bytes, range: range)
        }
        return terminatorLength == 0
    }

    private static func terminatorLength(in bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        let last = bytes[range.upperBound - 1]
        if last == 0x0A {
            return range.count >= 2 && bytes[range.upperBound - 2] == 0x0D ? 2 : 1
        }
        return last == 0x0D ? 1 : 0
    }

    private func encodedLineEnding() throws -> [UInt8] {
        let text = TabularTextCodec.utf8String(dialect.lineEnding.bytes)
        return try encode(text, row: 0, column: 0)
    }

    private func encode(_ text: String, row: Int, column: Int) throws -> [UInt8] {
        do {
            return try TabularTextCodec.encode(text, as: dialect.encoding)
        } catch let failure as UnencodableCharacter {
            throw TabularWriteError.unencodable(
                row: row,
                column: column,
                character: failure.character,
                encoding: failure.encoding
            )
        }
    }

    private func flush(_ buffer: inout [UInt8], to handle: FileHandle) throws {
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
        } catch {
            throw TabularWriteError.writeFailed(message: error.localizedDescription)
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
