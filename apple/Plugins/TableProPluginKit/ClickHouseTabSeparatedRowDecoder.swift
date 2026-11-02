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
        guard let columnNames else {
            self.columnNames = ClickHouseTabSeparatedBytes.fields(line).map(ClickHouseTabSeparatedBytes.headerText)
            return nil
        }
        guard header != nil else {
            header = Header(
                columns: columnNames,
                columnTypeNames: ClickHouseTabSeparatedBytes.fields(line).map(ClickHouseTabSeparatedBytes.headerText)
            )
            return nil
        }
        guard !line.isEmpty, let types = header?.columnTypeNames else { return nil }
        return ClickHouseTabSeparatedBytes.fields(line).enumerated().map { index, field in
            Self.cellValue(field, columnType: index < types.count ? types[index] : "")
        }
    }

    private static func cellValue(_ field: ArraySlice<UInt8>, columnType: String) -> PluginCellValue {
        guard !ClickHouseTabSeparatedBytes.isNullMarker(field) else { return .null }
        let value = ClickHouseTabSeparatedBytes.value(field, columnType: columnType)
        guard let text = String(bytes: value, encoding: .utf8) else { return .bytes(Data(value)) }
        return .text(text)
    }
}
