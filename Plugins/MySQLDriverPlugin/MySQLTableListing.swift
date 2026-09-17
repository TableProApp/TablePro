//
//  MySQLTableListing.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// Turns a table-list read into sidebar rows, and decides when `information_schema` gets the last word.
///
/// The catalog read comes first because it carries each table's comment and partition count. An empty
/// or refused answer from it is not final. Measured on MySQL 8.4.11, an account that can list a database
/// but none of its tables gets an empty set with no error, where `SHOW FULL TABLES FROM` that database
/// answers `ERROR 1044 Access denied`. MySQL-protocol proxies such as MyCat and DBLE answer
/// `SHOW FULL TABLES` from their own configuration and return nothing for `information_schema`.
internal enum MySQLTableListing {
    /// `CR_*` codes: the client failed, so the server never answered and a second read would fail too.
    static let clientErrorCodes: ClosedRange<UInt32> = 2_000...2_999

    /// Code 0 is an error the driver raised itself, which says nothing about what the server can answer.
    static func showFullTablesSettlesCatalogFailure(code: UInt32) -> Bool {
        code != 0 && !clientErrorCodes.contains(code)
    }

    /// A `SHOW FULL TABLES` row carries the name and type alone. A catalog row adds the comment and the
    /// partition count, so the same mapping reads both.
    static func tables(from rows: [[PluginCellValue]], listsSequencesAsTables: Bool) -> [PluginTableInfo] {
        rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeName = row[safe: 1]?.asText ?? "BASE TABLE"
            guard listsSequencesAsTables || typeName != "SEQUENCE" else { return nil }
            let isView = typeName.contains("VIEW")
            let comment = isView ? nil : row[safe: 2]?.asText?.nilIfEmpty
            let partitionCount = isView ? nil : row[safe: 3]?.asText.flatMap(Int.init)
            let type = isView ? "VIEW" : (partitionCount == nil ? "TABLE" : "PARTITIONED TABLE")
            return PluginTableInfo(name: name, type: type, comment: comment, partitionCount: partitionCount)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
