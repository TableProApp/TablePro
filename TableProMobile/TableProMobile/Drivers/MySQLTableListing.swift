import Foundation
import TableProModels

nonisolated internal enum MySQLTableListing {
    static func tables(fromShowFullTables rows: [[String?]], databaseType: DatabaseType) -> [TableInfo] {
        rows.compactMap { row in
            guard row.count >= 2, let name = row[0], let tableType = row[1] else { return nil }
            let normalizedType = normalized(tableType)
            if normalizedType == "SEQUENCE", hidesSequences(for: databaseType) {
                return nil
            }
            guard let kind = kind(forRawType: normalizedType) else { return nil }
            return TableInfo(name: name, type: kind, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    /// Nil for a row this list must not show at all.
    ///
    /// Measured on MariaDB 11.4.13 in one session: a temporary table shadowing a base table of the
    /// same name makes `SHOW FULL TABLES` list that name twice, as `TEMPORARY TABLE` then
    /// `BASE TABLE`, and `TableInfo.id` is the bare name here, so the list drew one id twice.
    ///
    /// An external table keeps its own kind rather than joining the system tables. `.systemTable`
    /// is row-editable here, so folding OceanBase's `EXTERNAL TABLE` into it offered Insert Row
    /// over a table the server refuses INSERT on, which the Mac app withholds.
    static func kind(forRawType rawType: String) -> TableInfo.TableKind? {
        switch rawType {
        case "VIEW", "SYSTEM VIEW":
            return .view
        case "SEQUENCE":
            return .sequence
        case "TEMPORARY", "TEMPORARY TABLE":
            return nil
        case "SYSTEM TABLE", "VIRTUAL TABLE":
            return .systemTable
        case "EXTERNAL TABLE":
            return .externalTable
        default:
            return .table
        }
    }

    private static func hidesSequences(for databaseType: DatabaseType) -> Bool {
        databaseType == .tidb
    }

    private static func normalized(_ rawType: String) -> String {
        rawType
            .uppercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
