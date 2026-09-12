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
    private var columnNames: [String]?

    public init() {}

    public mutating func consume(_ data: Data) -> [[PluginCellValue]] {
        guard !data.isEmpty else { return [] }

        var buffer = pendingBytes
        pendingBytes = []
        buffer.append(contentsOf: data)

        var rows: [[PluginCellValue]] = []
        var lineStart = 0
        for index in buffer.indices where buffer[index] == ClickHouseTabSeparatedBytes.lineSeparator {
            if let row = ingest(buffer[lineStart..<index]) {
                rows.append(row)
            }
            lineStart = index + 1
        }
        buffer.removeFirst(lineStart)
        pendingBytes = buffer
        return rows
    }

    /// A body that ended without its closing newline still holds one whole row.
    public mutating func finish() -> [[PluginCellValue]] {
        let buffer = pendingBytes
        pendingBytes = []
        guard !buffer.isEmpty, let row = ingest(buffer[...]) else { return [] }
        return [row]
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
        guard !line.isEmpty else { return nil }
        return ClickHouseTabSeparatedBytes.fields(line).map(Self.cellValue)
    }

    private static func cellValue(_ field: ArraySlice<UInt8>) -> PluginCellValue {
        guard !ClickHouseTabSeparatedBytes.isNullMarker(field) else { return .null }
        let value = ClickHouseTabSeparatedBytes.unescape(field)
        guard let text = String(bytes: value, encoding: .utf8) else { return .bytes(Data(value)) }
        return .text(text)
    }
}
