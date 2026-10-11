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
    let key: MySQLIndexKey
    let isNonUnique: Bool
    let type: String

    init(table: String, index: String, key: MySQLIndexKey, isNonUnique: Bool, type: String) {
        self.table = table
        self.index = index
        self.key = key
        self.isNonUnique = isNonUnique
        self.type = type
    }

    init?(
        table: String,
        index: String,
        column: String?,
        catalogExpression: String?,
        prefixLength: Int?,
        collation: String?,
        isNonUnique: Bool,
        type: String
    ) {
        let part: MySQLIndexKeyPart
        if let column {
            part = .column(column, prefixLength: prefixLength)
        } else if let catalogExpression {
            part = .expression(MySQLFunctionalKeyParts.unescaped(catalogExpression))
        } else {
            return nil
        }
        self.init(
            table: table,
            index: index,
            key: MySQLIndexKey(part: part, isDescending: collation == "D"),
            isNonUnique: isNonUnique,
            type: type
        )
    }
}

enum MySQLIndexGrouping {
    private struct Entry {
        let isUnique: Bool
        let type: String
        var keys: [MySQLIndexKey]
    }

    /// Rows must arrive in index-position order: a composite index takes its column order from the
    /// order they are appended, which is what the caller's `ORDER BY … SEQ_IN_INDEX` provides.
    ///
    /// Indexes are listed in the order their first row arrived. The dictionary that groups them
    /// iterates in a different order for every instance, so listing from it made two reads of one
    /// unchanged table disagree.
    static func group(_ rows: [MySQLIndexRow]) -> [String: [PluginIndexInfo]] {
        var order: [String: [String]] = [:]
        var byTable: [String: [String: Entry]] = [:]

        for row in rows {
            var indexes = byTable[row.table] ?? [:]
            if indexes[row.index] == nil {
                indexes[row.index] = Entry(isUnique: !row.isNonUnique, type: row.type, keys: [])
                order[row.table, default: []].append(row.index)
            }
            indexes[row.index]?.keys.append(row.key)
            byTable[row.table] = indexes
        }

        var grouped: [String: [PluginIndexInfo]] = [:]
        for (table, names) in order {
            let indexes = byTable[table] ?? [:]
            grouped[table] = names
                .compactMap { name -> PluginIndexInfo? in
                    guard let entry = indexes[name] else { return nil }
                    return info(name: name, entry: entry)
                }
                .sorted { $0.isPrimary && !$1.isPrimary }
        }
        return grouped
    }

    private static func info(name: String, entry: Entry) -> PluginIndexInfo {
        var prefixes: [String: Int] = [:]
        var expressions: [String] = []
        for key in entry.keys {
            switch key.part {
            case .column(let column, let prefixLength?):
                prefixes[column] = prefixLength
            case .expression(let expression):
                expressions.append(expression)
            case .column:
                break
            }
        }
        let spelling = entry.keys.contains(where: \.isDescending)
            ? mysqlIndexKeyClause(entry.keys, type: entry.type)
            : nil
        return PluginIndexInfo(
            name: name,
            columns: entry.keys.map(\.part.text),
            isUnique: entry.isUnique,
            isPrimary: name == "PRIMARY",
            type: entry.type,
            columnPrefixes: prefixes.isEmpty ? nil : prefixes,
            expressions: expressions.isEmpty ? nil : expressions,
            includedColumns: nil,
            ddlMethodAndKeys: spelling,
            ddlWhereClause: nil,
            isValid: nil
        )
    }
}
