//
//  SQLExportHelpers.swift
//  SQLExportPlugin
//

import Foundation

enum SQLExportHelpers {
    static func buildPaginatedQuery(
        tableRef: String,
        databaseTypeId: String,
        offset: Int,
        limit: Int
    ) -> String {
        switch databaseTypeId {
        case "Oracle":
            return "SELECT * FROM \(tableRef) ORDER BY 1 OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        case "MSSQL":
            return "SELECT * FROM \(tableRef) ORDER BY (SELECT NULL) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        default:
            return "SELECT * FROM \(tableRef) LIMIT \(limit) OFFSET \(offset)"
        }
    }
}
