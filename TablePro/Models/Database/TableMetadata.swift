//
//  TableMetadata.swift
//  TablePro
//
//  Model for table-level metadata
//

import Foundation

/// Represents table-level metadata fetched from database
struct TableMetadata {
    let tableName: String
    let dataSize: Int64?
    let indexSize: Int64?
    let totalSize: Int64?
    let avgRowLength: Int64?
    let rowCount: Int64?
    let comment: String?
    let engine: String?          // MySQL/MariaDB only
    let collation: String?       // MySQL/MariaDB only
    let createTime: Date?
    let updateTime: Date?

    /// Format a size in bytes to human readable format
    static func formatSize(_ bytes: Int64?) -> String {
        guard let bytes = bytes else { return "—" }
        if bytes == 0 { return "0 B" }

        let units = ["B", "KB", "MB", "GB", "TB"]
        let exponent = min(Int(log(Double(bytes)) / log(1_024)), units.count - 1)
        let size = Double(bytes) / pow(1_024, Double(exponent))

        if exponent == 0 {
            return "\(bytes) B"
        } else {
            return String(format: "%.1f %@", size, units[exponent])
        }
    }
}
