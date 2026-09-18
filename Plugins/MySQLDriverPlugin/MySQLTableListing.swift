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
            let rawType = normalized(row[safe: 1]?.asText ?? "BASE TABLE")
            guard listsSequencesAsTables || rawType != "SEQUENCE" else { return nil }
            guard !isSessionTemporary(rawType) else { return nil }
            let carriesTableDetail = !isViewLike(rawType) && rawType != "SEQUENCE"
            let comment = carriesTableDetail ? row[safe: 2]?.asText?.nilIfEmpty : nil
            let partitionCount = carriesTableDetail ? row[safe: 3]?.asText.flatMap(Int.init) : nil
            let type = kind(forRawType: rawType, isPartitioned: partitionCount != nil)
            return PluginTableInfo(name: name, type: type, comment: comment, partitionCount: partitionCount)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The type the app is told about, from the type the server answered with.
    ///
    /// Measured on MariaDB 11.4.13: `information_schema.TABLES` reports `SEQUENCE` for a sequence
    /// and `SYSTEM VERSIONED` for a table declared `WITH SYSTEM VERSIONING`, partitioned or not.
    /// OceanBase adds `EXTERNAL TABLE`, `SYSTEM TABLE`, `VIRTUAL TABLE` and `TMP TABLE`.
    ///
    /// An external table keeps its own kind even when it is partitioned, rather than being traded
    /// for `PARTITIONED TABLE`: the kind is what keeps row editing off, and the count rides along
    /// beside it.
    ///
    /// `TMP TABLE` is OceanBase's spelling and is unmeasured here, so it stays an ordinary table.
    /// If it turns out to shadow a base row the way MariaDB's `TEMPORARY` does, it belongs in
    /// `isSessionTemporary` instead.
    static func kind(forRawType rawType: String, isPartitioned: Bool) -> String {
        switch rawType {
        case "VIEW", "SYSTEM VIEW":
            return "VIEW"
        case "SEQUENCE":
            return "SEQUENCE"
        case "SYSTEM TABLE", "VIRTUAL TABLE":
            return "SYSTEM TABLE"
        case "EXTERNAL TABLE":
            return "EXTERNAL TABLE"
        case "SYSTEM VERSIONED":
            return isPartitioned ? "SYSTEM VERSIONED PARTITIONED TABLE" : "SYSTEM VERSIONED TABLE"
        default:
            return isPartitioned ? "PARTITIONED TABLE" : "TABLE"
        }
    }

    /// A temporary table shadows a base table of the same name in both channels.
    ///
    /// Measured on MariaDB 11.4.13 in one session: after `CREATE TEMPORARY TABLE plain` over a base
    /// table `plain`, `SHOW FULL TABLES` lists `plain` twice as `TEMPORARY TABLE` then `BASE TABLE`,
    /// and `information_schema.TABLES` lists it twice as `TEMPORARY` then `BASE TABLE`. The two rows
    /// share one `TableInfo.id`, so the sidebar drew the name twice. MySQL 8.4.11 lists a temporary
    /// table in neither channel, and the pooled metadata connection cannot see one anyway.
    private static func isSessionTemporary(_ rawType: String) -> Bool {
        rawType == "TEMPORARY" || rawType == "TEMPORARY TABLE"
    }

    private static func isViewLike(_ rawType: String) -> Bool {
        rawType == "VIEW" || rawType == "SYSTEM VIEW"
    }

    private static func normalized(_ rawType: String) -> String {
        rawType
            .uppercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
