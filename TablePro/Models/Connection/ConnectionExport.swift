//
//  ConnectionExport.swift
//  TablePro
//

import Foundation
import TableProImport

extension ExportableConnection {
    var displaySubtitle: String {
        if type == "SQLite" || type == "DuckDB" {
            return database.isEmpty
                ? type
                : (database as NSString).abbreviatingWithTildeInPath
        }
        return "\(host):\(port)"
    }
}
