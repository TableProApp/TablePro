import Foundation
import TableProModels

nonisolated internal enum MySQLTableListing {
    static func tables(fromShowFullTables rows: [[String?]], databaseType: DatabaseType) -> [TableInfo] {
        rows.compactMap { row in
            guard row.count >= 2, let name = row[0], let tableType = row[1] else { return nil }
            let normalizedType = tableType.uppercased()
            if normalizedType == "SEQUENCE", hidesSequences(for: databaseType) {
                return nil
            }
            let kind: TableInfo.TableKind = normalizedType == "VIEW" ? .view : .table
            return TableInfo(name: name, type: kind, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    private static func hidesSequences(for databaseType: DatabaseType) -> Bool {
        databaseType == .tidb
    }
}
