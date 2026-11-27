import Foundation

/// The streaming half of `ClickHouseResponseClassifier`, for the reads that hand rows back as they
/// arrive and so can never hold the whole response. A chunk boundary falls wherever the network
/// put it, so the bytes it cut in half are kept until the line they belong to is whole: a field is
/// offered to a text decode only once nothing more can be appended to it.
///
/// A value that is not valid UTF-8 stays `.bytes`, decided per value rather than per column the
/// way `classify` decides it. Demoting a column means rewriting the rows already handed over, and
/// a stream has no way back to them.
public struct ClickHouseTabSeparatedRowDecoder: Sendable {
    public struct Header: Equatable, Sendable {
        public let columns: [String]
        public let columnTypeNames: [String]

        public init(columns: [String], columnTypeNames: [String]) {
            self.columns = columns
            self.columnTypeNames = columnTypeNames
        }
    }

    public private(set) var header: Header?

    private var pendingBytes: [UInt8] = []
    // The pending bytes already searched for a separator, so a line split over many chunks is scanned once.
    private var searchedCount = 0
    private var columnNames: [String]?
    private var literalSyntaxColumns: [Bool] = []

    public init() {}

    public mutating func consume(_ data: Data) -> [[PluginCellValue]] {
        guard !data.isEmpty else { return [] }

        pendingBytes.append(contentsOf: data)

        var rows: [[PluginCellValue]] = []
        var lineStart = 0
        var searchFrom = searchedCount
        while let lineEnd = Self.lineSeparatorIndex(in: pendingBytes, from: searchFrom) {
            if let row = ingest(pendingBytes[lineStart..<lineEnd]) {
                rows.append(row)
            }
            lineStart = lineEnd + 1
            searchFrom = lineStart
        }
        if lineStart > 0 {
            pendingBytes.removeFirst(lineStart)
        }
        searchedCount = pendingBytes.count
        return rows
    }

    // A body that ended without its closing newline still holds one whole row.
    public mutating func finish() -> [[PluginCellValue]] {
        let buffer = pendingBytes
        pendingBytes = []
        searchedCount = 0
        guard !buffer.isEmpty, let row = ingest(buffer[...]) else { return [] }
        return [row]
    }

    private static func lineSeparatorIndex(in bytes: [UInt8], from start: Int) -> Int? {
        bytes.withUnsafeBufferPointer { buffer -> Int? in
            guard start < buffer.count, let base = buffer.baseAddress,
                  let found = memchr(base + start, Int32(ClickHouseTabSeparatedBytes.lineSeparator), buffer.count - start)
            else { return nil }
            return UnsafeRawPointer(found) - UnsafeRawPointer(base)
        }
    }

    private mutating func ingest(_ line: ArraySlice<UInt8>) -> [PluginCellValue]? {
        line.withUnsafeBufferPointer { ingest($0) }
    }

    private mutating func ingest(_ line: UnsafeBufferPointer<UInt8>) -> [PluginCellValue]? {
        guard let columnNames else {
            self.columnNames = ClickHouseTabSeparatedBytes.headerTexts(line)
            return nil
        }
        guard header != nil else {
            let types = ClickHouseTabSeparatedBytes.headerTexts(line)
            header = Header(columns: columnNames, columnTypeNames: types)
            literalSyntaxColumns = types.map(ClickHouseTabSeparatedBytes.writesLiteralSyntax)
            return nil
        }
        guard !line.isEmpty else { return nil }
        let literalSyntaxColumns = literalSyntaxColumns
        var row: [PluginCellValue] = []
        row.reserveCapacity(literalSyntaxColumns.count)
        ClickHouseTabSeparatedBytes.forEachField(line) { field in
            let index = row.count
            row.append(ClickHouseTabSeparatedBytes.cellValue(
                field,
                writesLiteralSyntax: index < literalSyntaxColumns.count && literalSyntaxColumns[index]
            ))
        }
        return row
    }
}
