import Foundation

/// The byte patterns a file must carry, at fixed offsets from its start, to be one an engine wrote.
///
/// Declared only for a format whose driver opens the file by path whatever it is named, because
/// that is the only case where recognising it changes anything. Measured against DuckDB 1.5.4: its
/// own storage opens from `warehouse.db`, `plain` and `thing.bin` alike, while a Parquet file under
/// any name but `.parquet` is refused with "not a valid DuckDB database file". sqlite3 never reads
/// the name at all.
///
/// Every marker has to match, which is what keeps a short one honest: `DUCK` alone is four bytes
/// that `SELECT 'DUCK';` also spells at offset 8.
public struct DatabaseFileSignature: Sendable, Hashable {
    public struct Marker: Sendable, Hashable {
        public let offset: Int
        public let bytes: [UInt8]
    }

    public let markers: [Marker]

    public static func magic(_ ascii: String, at offset: Int = 0) -> DatabaseFileSignature {
        DatabaseFileSignature(markers: [Marker(offset: offset, bytes: Array(ascii.utf8))])
    }

    public func andZeroes(at offset: Int, count: Int) -> DatabaseFileSignature {
        DatabaseFileSignature(
            markers: markers + [Marker(offset: offset, bytes: [UInt8](repeating: 0, count: count))]
        )
    }

    public var requiredPrefixLength: Int {
        markers.reduce(0) { max($0, $1.offset + $1.bytes.count) }
    }

    public var totalMarkerLength: Int {
        markers.reduce(0) { $0 + $1.bytes.count }
    }

    public func matches(_ prefix: [UInt8]) -> Bool {
        markers.allSatisfy { marker in
            let end = marker.offset + marker.bytes.count
            guard marker.offset >= 0, prefix.count >= end else { return false }
            return Array(prefix[marker.offset ..< end]) == marker.bytes
        }
    }
}
