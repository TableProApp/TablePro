//
//  CrossEngineKeyWidth.swift
//  TablePro
//
//  Whether a key the source could index fits in the target's index entries.
//
//  Judged on the target's types, not the source's. A PostgreSQL
//  `varchar(5000)` is bounded where it is read and unbounded where it is
//  written, as an `NVARCHAR(MAX)` on SQL Server, and a `varchar(1000)` is
//  4,000 bytes on MySQL, past the 3,072 bytes an InnoDB index takes.
//

import Foundation

internal enum CrossEngineKeyWidth {
    /// The length a text key is cut to where the engine needs one. 255 is what MySQL's own tooling
    /// uses, and at four bytes a character three such parts fit in one 3,072-byte key.
    internal static let prefixLength = 255

    // MARK: - Primary keys

    /// Respells the primary key columns the target cannot index as declared.
    ///
    /// MySQL refuses `PRIMARY KEY` on a `LONGTEXT` outright, SQL Server on an `NVARCHAR(MAX)`, and
    /// Oracle cannot index a `CLOB` at all, so each of those gets a bounded spelling. MySQL also
    /// refuses a key wider than 3,072 bytes, so the widest text or binary part is cut to 255 until
    /// the key fits. A row whose key needs more than that is refused on insert, which is why each
    /// respelling is a note.
    internal static func boundPrimaryKey(
        _ columns: inout [CrossEngineColumnDraft],
        keyColumns: Set<String>,
        family: SQLTypeFamily
    ) {
        let keyIndexes = columns.indices.filter { keyColumns.contains(columns[$0].name.lowercased()) }
        for index in keyIndexes where isUnbounded(columns[index].targetKind) {
            guard let spelling = boundedSpelling(for: columns[index].targetKind, family: family) else { continue }
            columns[index].respell(spelling, fidelity: .approximated, reason: String(
                format: String(localized: "A key column cannot be unbounded here, so it is created as %@."),
                spelling
            ))
        }

        guard family == .mysql else { return }
        while keyBytes(keyIndexes.map { columns[$0].targetKind }) > MySQLStorageWidth.maximumKeyBytes {
            let cuttable = keyIndexes.filter { isCuttable(columns[$0].targetKind, prefix: nil) }
            guard let widest = cuttable.max(by: {
                keyBytes([columns[$0].targetKind]) < keyBytes([columns[$1].targetKind])
            }) else { return }
            let spelling = isBinary(columns[widest].targetKind)
                ? "VARBINARY(\(prefixLength))" : "VARCHAR(\(prefixLength))"
            columns[widest].respell(spelling, fidelity: .approximated, reason: String(
                format: String(
                    localized: "At their declared lengths the key's columns pass the 3,072 bytes MySQL can index, so this one is %@."
                ),
                spelling
            ))
        }
    }

    private static func boundedSpelling(for kind: CanonicalTypeKind, family: SQLTypeFamily) -> String? {
        switch family {
        case .mysql:
            return isBinary(kind) ? "VARBINARY(\(prefixLength))" : "VARCHAR(\(prefixLength))"
        case .mssql:
            return isBinary(kind) ? "VARBINARY(450)" : "NVARCHAR(450)"
        case .oracle:
            return isBinary(kind) ? "RAW(2000)" : "VARCHAR2(2000)"
        case .postgres, .sqlite, .clickhouse, .duckdb, .generic:
            return nil
        }
    }

    // MARK: - Indexes

    /// The key prefixes a MySQL index needs, or nil when no prefix brings it under 3,072 bytes.
    ///
    /// An unbounded part takes a 255 prefix, which MySQL needs before it indexes one at all. Then,
    /// while the key is too wide, the widest part still longer than 255 is cut to 255. Cutting the
    /// widest first leaves the other parts whole, and a whole part is a stronger index.
    internal static func mysqlPrefixes(
        columns: [String],
        declared: [String: Int],
        kinds: [String: CanonicalTypeKind]
    ) -> [String: Int]? {
        var prefixes = declared
        for column in columns where isUnbounded(kinds[column.lowercased()]) {
            prefixes[column] = min(prefixes[column] ?? prefixLength, prefixLength)
        }

        func width(_ column: String) -> Int {
            guard let kind = kinds[column.lowercased()] else { return 0 }
            return MySQLStorageWidth.keyBytes(kind, prefix: prefixes[column]) ?? 0
        }

        while columns.reduce(0, { $0 + width($1) }) > MySQLStorageWidth.maximumKeyBytes {
            let cuttable = columns.filter { column in
                guard let kind = kinds[column.lowercased()] else { return false }
                return isCuttable(kind, prefix: prefixes[column])
            }
            guard let widest = cuttable.max(by: { width($0) < width($1) }) else { return nil }
            prefixes[widest] = prefixLength
        }
        return prefixes
    }

    // MARK: - Kinds

    /// A kind no engine with size-limited index entries can take in a key without a bound or a
    /// prefix.
    internal static func isUnbounded(_ kind: CanonicalTypeKind?) -> Bool {
        switch kind {
        case .text(let length, _), .binary(let length, _): return length == nil
        case .json, .xml, .spatial, .array: return true
        default: return false
        }
    }

    private static func isCuttable(_ kind: CanonicalTypeKind, prefix: Int?) -> Bool {
        switch kind {
        case .text(let length?, _), .binary(let length?, _):
            return min(length, prefix ?? length) > prefixLength
        default:
            return false
        }
    }

    private static func isBinary(_ kind: CanonicalTypeKind) -> Bool {
        guard case .binary = kind else { return false }
        return true
    }

    private static func keyBytes(_ kinds: [CanonicalTypeKind]) -> Int {
        kinds.reduce(0) { $0 + (MySQLStorageWidth.keyBytes($1) ?? 0) }
    }
}
