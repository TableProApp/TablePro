//
//  MySQLIndexGrouping.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// One row of `SHOW INDEX` or `INFORMATION_SCHEMA.STATISTICS`, in the fields both spell the same.
struct MySQLIndexRow {
    let table: String
    let index: String
    let column: String
    let isNonUnique: Bool
    let type: String
    let prefixLength: Int?
}

enum MySQLIndexGrouping {
    /// Rows must arrive in index-position order: a composite index takes its column order from the
    /// order they are appended, which is what the caller's `ORDER BY … SEQ_IN_INDEX` provides.
    ///
    /// Indexes are listed in the order their first row arrived. The dictionary that groups them
    /// iterates in a different order for every instance, so listing from it made two reads of one
    /// unchanged table disagree.
    static func group(_ rows: [MySQLIndexRow]) -> [String: [PluginIndexInfo]] {
        var order: [String: [String]] = [:]
        var byTable: [String: [String: (columns: [String], isUnique: Bool, type: String, prefixes: [String: Int])]] = [:]

        for row in rows {
            var indexes = byTable[row.table] ?? [:]
            if var existing = indexes[row.index] {
                existing.columns.append(row.column)
                if let prefix = row.prefixLength {
                    existing.prefixes[row.column] = prefix
                }
                indexes[row.index] = existing
            } else {
                var prefixes: [String: Int] = [:]
                if let prefix = row.prefixLength {
                    prefixes[row.column] = prefix
                }
                indexes[row.index] = (
                    columns: [row.column], isUnique: !row.isNonUnique, type: row.type, prefixes: prefixes
                )
                order[row.table, default: []].append(row.index)
            }
            byTable[row.table] = indexes
        }

        var grouped: [String: [PluginIndexInfo]] = [:]
        for (table, names) in order {
            let indexes = byTable[table] ?? [:]
            grouped[table] = names
                .compactMap { name -> PluginIndexInfo? in
                    guard let info = indexes[name] else { return nil }
                    return PluginIndexInfo(
                        name: name, columns: info.columns, isUnique: info.isUnique,
                        isPrimary: name == "PRIMARY", type: info.type,
                        columnPrefixes: info.prefixes.isEmpty ? nil : info.prefixes
                    )
                }
                .sorted { $0.isPrimary && !$1.isPrimary }
        }
        return grouped
    }
}
