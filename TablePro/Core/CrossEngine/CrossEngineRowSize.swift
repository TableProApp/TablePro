//
//  CrossEngineRowSize.swift
//  TablePro
//
//  Whether a table's columns, at the lengths they declare, fit in a MySQL row.
//
//  MySQL refuses a table whose row may pass 65,535 bytes, and InnoDB one whose
//  record may pass 8,126, with ERROR 1118 either way. A PostgreSQL table with
//  33 `varchar(500)` columns or 41 `varchar(50)` ones copies nowhere else as
//  easily, because PostgreSQL moves a long value out of the row itself. The
//  answer MySQL gives in its own error is the one taken here: the widest column
//  becomes `TEXT`, which is stored apart from the row, until the table fits.
//

import Foundation

internal enum CrossEngineRowSize {
    /// Respells the columns a MySQL table cannot hold in its row, widest first.
    ///
    /// Widest is measured against the limit being passed, because the two count different bytes:
    /// a `VARCHAR(1000)` is 4,002 bytes of the 65,535 and 41 of the 8,126, while a `VARCHAR(63)` is
    /// 253 of both. Key columns are never moved, since MySQL cannot key a `TEXT`, and a column an
    /// index covers is moved only once no other column helps, because an index over `TEXT` is cut to
    /// a prefix.
    internal static func fitMySQLRow(
        _ columns: inout [CrossEngineColumnDraft],
        keyColumns: Set<String>,
        indexedColumns: Set<String>
    ) {
        let hasPrimaryKey = !keyColumns.isEmpty
        while let limit = MySQLStorageWidth.exceededLimit(
            of: measured(columns, keyColumns: keyColumns), hasPrimaryKey: hasPrimaryKey
        ) {
            let movable = columns.indices.compactMap { index -> (index: Int, isIndexed: Bool, saving: Int)? in
                let name = columns[index].name.lowercased()
                guard !keyColumns.contains(name) else { return nil }
                let saving = savedBytes(moving: columns[index].targetKind, under: limit)
                guard saving > 0 else { return nil }
                return (index, indexedColumns.contains(name), saving)
            }
            guard let widest = movable.max(by: { lhs, rhs in
                guard lhs.isIndexed == rhs.isIndexed else { return lhs.isIndexed }
                return lhs.saving < rhs.saving
            }), let spelling = outOfRowSpelling(for: columns[widest.index].targetKind) else { return }
            columns[widest.index].respell(spelling, fidelity: .widened, reason: reason(for: limit, spelling: spelling))
        }
    }

    private static func measured(
        _ columns: [CrossEngineColumnDraft],
        keyColumns: Set<String>
    ) -> [MySQLStorageWidth.Column] {
        columns.map {
            MySQLStorageWidth.Column(
                kind: $0.targetKind,
                isNullable: $0.isNullable && !keyColumns.contains($0.name.lowercased())
            )
        }
    }

    private static func savedBytes(moving kind: CanonicalTypeKind, under limit: MySQLStorageWidth.Limit) -> Int {
        guard outOfRowSpelling(for: kind) != nil else { return 0 }
        let outOfRow = CanonicalTypeKind.text(length: nil, isFixed: false)
        switch limit {
        case .row: return MySQLStorageWidth.rowBytes(kind) - MySQLStorageWidth.rowBytes(outOfRow)
        case .record: return MySQLStorageWidth.recordBytes(kind) - MySQLStorageWidth.recordBytes(outOfRow)
        }
    }

    /// `TEXT` and `BLOB` hold 65,535 bytes, enough for every length the renderer writes.
    private static func outOfRowSpelling(for kind: CanonicalTypeKind) -> String? {
        switch kind {
        case .text(let length?, _):
            return length * MySQLStorageWidth.bytesPerCharacter <= 65_535 ? "TEXT" : "LONGTEXT"
        case .binary(let length?, _):
            return length <= 65_535 ? "BLOB" : "LONGBLOB"
        default:
            return nil
        }
    }

    private static func reason(for limit: MySQLStorageWidth.Limit, spelling: String) -> String {
        switch limit {
        case .row:
            return String(
                format: String(
                    localized: "At their declared lengths the columns pass MySQL's 65,535-byte row limit, so this one is %@, which does not enforce a length."
                ),
                spelling
            )
        case .record:
            return String(
                format: String(
                    localized: "At their declared lengths the columns pass InnoDB's 8,126-byte record limit, so this one is %@, which does not enforce a length."
                ),
                spelling
            )
        }
    }
}
