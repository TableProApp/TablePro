//
//  MySQLStorageWidth.swift
//  TablePro
//
//  How many bytes a MySQL table spends on each column, in the three places a
//  CREATE TABLE is refused for size.
//
//  A copy that keeps every declared length is a copy that can be too wide
//  for MySQL, where a PostgreSQL table of the same columns is not: an index
//  key over 3,072 bytes is refused with ERROR 1071, and a row over 65,535
//  bytes, or one InnoDB could not fit in half of a 16 KB page, with ERROR
//  1118. Each limit counts different bytes, so each has its own measure here.
//
//  Measured on MariaDB 12.3.3 (utf8mb4, ROW_FORMAT=DYNAMIC, 16 KB pages,
//  innodb_strict_mode on), where 600 random tables and the exact boundary of
//  each limit all agreed with these sums. MySQL documents the same three
//  limits and the same defaults.
//
//  Every character is four bytes, because a translated column carries no
//  character set and the table's default is utf8mb4.
//

import Foundation

internal enum MySQLStorageWidth {
    internal static let maximumKeyBytes = 3_072
    internal static let maximumRowBytes = 65_535
    /// InnoDB refuses a record whose worst case reaches half of a 16 KB page, 8,126 bytes.
    internal static let maximumRecordBytes = 8_125
    internal static let bytesPerCharacter = 4

    internal struct Column: Sendable {
        internal let kind: CanonicalTypeKind
        internal let isNullable: Bool

        internal init(kind: CanonicalTypeKind, isNullable: Bool) {
            self.kind = kind
            self.isNullable = isNullable
        }
    }

    internal enum Limit: Sendable {
        case row
        case record
    }

    // MARK: - Tables

    /// The limit the table passes first, or nil when it fits both.
    internal static func exceededLimit(of columns: [Column], hasPrimaryKey: Bool) -> Limit? {
        if rowBytes(of: columns) > maximumRowBytes { return .row }
        if recordBytes(of: columns, hasPrimaryKey: hasPrimaryKey) > maximumRecordBytes { return .record }
        return nil
    }

    /// The server's own count: each column's storage and the bitmap of nullable columns.
    internal static func rowBytes(of columns: [Column]) -> Int {
        columns.reduce(nullBitmapBytes(columns)) { $0 + rowBytes($1.kind) }
    }

    /// InnoDB's worst case for one clustered index record: a five-byte header, the null bitmap, the
    /// transaction and rollback pointers, a row id when there is no primary key, and each column.
    internal static func recordBytes(of columns: [Column], hasPrimaryKey: Bool) -> Int {
        let header = 5 + nullBitmapBytes(columns) + 13 + (hasPrimaryKey ? 0 : 6)
        return columns.reduce(header) { $0 + recordBytes($1.kind) }
    }

    private static func nullBitmapBytes(_ columns: [Column]) -> Int {
        (columns.filter(\.isNullable).count + 7) / 8
    }

    // MARK: - Columns

    internal static func rowBytes(_ kind: CanonicalTypeKind) -> Int {
        switch storage(kind) {
        case .fixed(let bytes): return bytes
        case .padded(let maximumBytes): return maximumBytes
        case .variable(let maximumBytes): return maximumBytes + (maximumBytes > 255 ? 2 : 1)
        case .outOfRow: return outOfRowPointerBytes
        }
    }

    /// A variable column over 255 bytes, and every `TEXT` or `BLOB`, may be moved off the page, so
    /// the record counts only the 40 bytes it can keep in place and a length byte.
    internal static func recordBytes(_ kind: CanonicalTypeKind) -> Int {
        switch storage(kind) {
        case .fixed(let bytes): return bytes
        case .padded(let maximumBytes), .variable(let maximumBytes):
            return maximumBytes > 255 ? offPageRecordBytes : maximumBytes + 1
        case .outOfRow: return offPageRecordBytes
        }
    }

    /// The bytes one key part takes, or nil for a column MySQL indexes only by a prefix.
    internal static func keyBytes(_ kind: CanonicalTypeKind, prefix: Int? = nil) -> Int? {
        switch kind {
        case .text(let length, _):
            guard let characters = shorter(length, prefix) else { return nil }
            return characters * bytesPerCharacter
        case .binary(let length, _):
            return shorter(length, prefix)
        default:
            switch storage(kind) {
            case .fixed(let bytes), .padded(let bytes), .variable(let bytes): return bytes
            case .outOfRow: return prefix.map { $0 * bytesPerCharacter }
            }
        }
    }

    private static let outOfRowPointerBytes = 12
    private static let offPageRecordBytes = 41

    private static func shorter(_ length: Int?, _ prefix: Int?) -> Int? {
        guard let length else { return prefix }
        return min(length, prefix ?? length)
    }

    // MARK: - Storage

    private enum Storage {
        case fixed(Int)
        /// A `CHAR` in a multibyte character set: no length prefix in the row, variable in InnoDB.
        case padded(Int)
        case variable(Int)
        case outOfRow
    }

    private static func storage(_ kind: CanonicalTypeKind) -> Storage {
        switch kind {
        case .boolean: return .fixed(1)
        case .integer(let bytes):
            return .fixed(bytes <= 8 ? bytes : decimalBytes(precision: 39, scale: 0))
        case .decimal(let precision, let scale):
            return .fixed(decimalBytes(precision: precision ?? 65, scale: scale ?? 0))
        case .floatingPoint(let bits): return .fixed(bits <= 32 ? 4 : 8)
        case .text(let length, let isFixed):
            guard let length else { return .outOfRow }
            let bytes = length * bytesPerCharacter
            return isFixed ? .padded(bytes) : .variable(bytes)
        case .binary(let length, let isFixed):
            guard let length else { return .outOfRow }
            return isFixed ? .fixed(length) : .variable(length)
        case .date: return .fixed(3)
        case .time(let precision, _): return .fixed(3 + fractionalSecondsBytes(precision))
        case .timestamp(let precision, _): return .fixed(5 + fractionalSecondsBytes(precision))
        case .uuid: return .padded(36 * bytesPerCharacter)
        case .interval: return .variable(64 * bytesPerCharacter)
        case .enumeration(let values): return .fixed(values.count > 255 ? 2 : 1)
        case .bitString(let length): return .fixed(((length ?? 1) + 7) / 8)
        case .money: return .fixed(decimalBytes(precision: 19, scale: 4))
        case .json, .xml, .spatial, .array, .unsupported: return .outOfRow
        }
    }

    private static func fractionalSecondsBytes(_ precision: Int?) -> Int {
        ((precision ?? 0) + 1) / 2
    }

    /// MySQL packs a decimal nine digits to four bytes, on each side of the point separately.
    internal static func decimalBytes(precision: Int, scale: Int) -> Int {
        let leftoverBytes = [0, 1, 1, 2, 2, 3, 3, 4, 4]
        func bytes(forDigits digits: Int) -> Int {
            digits / 9 * 4 + leftoverBytes[digits % 9]
        }
        let fraction = max(0, min(scale, precision))
        return bytes(forDigits: precision - fraction) + bytes(forDigits: fraction)
    }
}
