//
//  CrossEngineKeyBudget.swift
//  TablePro
//
//  How many bytes an engine lets one key take, and what each part of it costs.
//
//  An engine that keeps its index entries inside a page caps how wide one may
//  be, and three of the targets judge that from the declared types before a
//  row exists. MySQL refuses a key past 3,072 bytes with ERROR 1071, measured
//  on MySQL 8.4.11 and MariaDB 12.3.3. Oracle documents ORA-01450 past 6,398
//  bytes at its default 8 KB block, counting each part at its declared width
//  plus one. SQL Server documents 900 bytes for a clustered index and 1,700 for
//  any other, and refuses at CREATE only a key whose fixed-length parts pass
//  that: a key of longer variable parts is created, and a row whose key is
//  longer is refused.
//
//  A length counted in characters is counted at its widest: four bytes on
//  MySQL's utf8mb4 and Oracle's AL32UTF8, two on SQL Server's NVARCHAR.
//

import Foundation

internal struct CrossEngineKeyBudget: Sendable {
    /// Which parts the engine adds up when the key is created.
    internal enum Check: Sendable {
        case declaredWidth
        case fixedWidth
    }

    /// A SQL Server primary key is clustered unless another index already is, so it gets the
    /// clustered limit.
    internal let primaryKeyBytes: Int
    internal let indexBytes: Int
    internal let check: Check
    /// MySQL builds an index for every foreign key, which then has to fit like any other. SQL
    /// Server and Oracle build none.
    internal let indexesForeignKeys: Bool
    private let family: SQLTypeFamily
    private let bytesPerCharacter: Int
    private let boundedTextLength: Int
    private let boundedBinaryLength: Int

    internal static func of(_ family: SQLTypeFamily) -> CrossEngineKeyBudget? {
        switch family {
        case .mysql:
            return CrossEngineKeyBudget(
                primaryKeyBytes: MySQLStorageWidth.maximumKeyBytes,
                indexBytes: MySQLStorageWidth.maximumKeyBytes,
                check: .declaredWidth,
                indexesForeignKeys: true,
                family: family,
                bytesPerCharacter: MySQLStorageWidth.bytesPerCharacter,
                boundedTextLength: CrossEngineKeyWidth.prefixLength,
                boundedBinaryLength: CrossEngineKeyWidth.prefixLength
            )
        case .mssql:
            return CrossEngineKeyBudget(
                primaryKeyBytes: 900,
                indexBytes: 1_700,
                check: .fixedWidth,
                indexesForeignKeys: false,
                family: family,
                bytesPerCharacter: 2,
                boundedTextLength: 450,
                boundedBinaryLength: 450
            )
        case .oracle:
            return CrossEngineKeyBudget(
                primaryKeyBytes: 6_398,
                indexBytes: 6_398,
                check: .declaredWidth,
                indexesForeignKeys: false,
                family: family,
                bytesPerCharacter: 4,
                boundedTextLength: 1_000,
                boundedBinaryLength: 2_000
            )
        case .postgres, .sqlite, .clickhouse, .duckdb, .generic:
            return nil
        }
    }

    // MARK: - Widths

    /// The bytes the engine adds up for these parts when it creates the key, or nil when one of
    /// them has no width at all.
    internal func checkedBytes(_ kinds: [CanonicalTypeKind]) -> Int? {
        switch check {
        case .declaredWidth:
            return declaredBytes(kinds)
        case .fixedWidth:
            return declaredBytes(kinds.filter { !isVariableLength($0) })
        }
    }

    /// The bytes the parts may take at their declared lengths, or nil when one of them has none.
    internal func declaredBytes(_ kinds: [CanonicalTypeKind]) -> Int? {
        var total = overheadBytes(partCount: kinds.count)
        for kind in kinds {
            guard let bytes = partBytes(kind) else { return nil }
            total += bytes
        }
        return total
    }

    /// Oracle adds one byte a part to the widths of the parts.
    internal func overheadBytes(partCount: Int) -> Int {
        family == .oracle ? partCount : 0
    }

    internal func partBytes(_ kind: CanonicalTypeKind) -> Int? {
        switch family {
        case .mysql: return MySQLStorageWidth.keyBytes(kind)
        case .mssql: return Self.mssqlBytes(kind)
        case .oracle: return Self.oracleBytes(kind)
        case .postgres, .sqlite, .clickhouse, .duckdb, .generic: return nil
        }
    }

    // MARK: - Lengths

    /// The declared length of a text or binary part, the only kinds a key can be cut on.
    internal func length(of kind: CanonicalTypeKind) -> Int? {
        switch kind {
        case .text(let length, _), .binary(let length, _): return length
        default: return nil
        }
    }

    /// What an unbounded part is given, and the first length a longer one is cut to.
    internal func boundedLength(of kind: CanonicalTypeKind) -> Int {
        isBinary(kind) ? boundedBinaryLength : boundedTextLength
    }

    /// The longest a part of this kind may declare and still take no more than these bytes.
    internal func length(of kind: CanonicalTypeKind, within bytes: Int) -> Int {
        isBinary(kind) ? bytes : bytes / bytesPerCharacter
    }

    internal func isVariableLength(_ kind: CanonicalTypeKind) -> Bool {
        switch kind {
        case .text(_, let isFixed), .binary(_, let isFixed): return !isFixed
        default: return false
        }
    }

    /// Always the variable spelling, so a cut part never pads its values out to the new length.
    internal func spelling(for kind: CanonicalTypeKind, length: Int) -> String {
        let binary = isBinary(kind)
        switch family {
        case .mysql: return binary ? "VARBINARY(\(length))" : "VARCHAR(\(length))"
        case .mssql: return binary ? "VARBINARY(\(length))" : "NVARCHAR(\(length))"
        case .oracle: return binary ? "RAW(\(length))" : "VARCHAR2(\(length) CHAR)"
        case .postgres, .sqlite, .clickhouse, .duckdb, .generic:
            return binary ? "VARBINARY(\(length))" : "VARCHAR(\(length))"
        }
    }

    private func isBinary(_ kind: CanonicalTypeKind) -> Bool {
        guard case .binary = kind else { return false }
        return true
    }

    // MARK: - SQL Server

    /// SQL Server's documented storage sizes for the types its renderer writes.
    private static func mssqlBytes(_ kind: CanonicalTypeKind) -> Int? {
        switch kind {
        case .boolean: return 1
        case .integer(let bytes): return bytes
        case .decimal(let precision, _): return mssqlDecimalBytes(precision: precision ?? 38)
        case .floatingPoint(let bits): return bits <= 32 ? 4 : 8
        case .money: return 8
        case .text(let length, _): return length.map { $0 * 2 }
        case .binary(let length, _): return length
        case .date: return 3
        case .time(let precision, _): return 3 + mssqlFractionBytes(precision)
        case .timestamp(let precision, let hasTimeZone):
            return 6 + mssqlFractionBytes(precision) + (hasTimeZone ? 2 : 0)
        case .uuid: return 16
        case .interval: return 128
        case .enumeration(let values): return SQLTypeRenderer.longestLabel(in: values) * 2
        case .bitString(let length): return ((length ?? 1) + 7) / 8
        case .json, .xml, .spatial, .array, .unsupported: return nil
        }
    }

    private static func mssqlDecimalBytes(precision: Int) -> Int {
        switch precision {
        case ...9: return 5
        case 10...19: return 9
        case 20...28: return 13
        default: return 17
        }
    }

    /// Seconds to two places take no extra byte, to four take one, and to seven take two. A time
    /// with no precision declared keeps seven.
    private static func mssqlFractionBytes(_ precision: Int?) -> Int {
        switch precision ?? 7 {
        case ...2: return 0
        case 3...4: return 1
        default: return 2
        }
    }

    // MARK: - Oracle

    /// Oracle's documented key widths: a character column at its defined width, which in AL32UTF8 is
    /// four bytes a character up to the type's own byte ceiling, a number at 22 and a `DATE` at 7.
    private static func oracleBytes(_ kind: CanonicalTypeKind) -> Int? {
        switch kind {
        case .boolean, .integer, .decimal, .money: return 22
        case .floatingPoint(let bits): return bits <= 32 ? 4 : 8
        case .text(let length, let isFixed): return length.map { min($0 * 4, isFixed ? 2_000 : 4_000) }
        case .binary(let length, _): return length
        case .date: return 7
        case .timestamp(let precision, let hasTimeZone):
            guard !hasTimeZone else { return 13 }
            return precision == 0 ? 7 : 11
        case .time, .interval: return 11
        case .uuid: return 144
        case .enumeration(let values): return min(SQLTypeRenderer.longestLabel(in: values) * 4, 4_000)
        case .bitString, .json, .xml, .spatial, .array, .unsupported: return nil
        }
    }
}
