//
//  SQLiteIndexCatalog.swift
//  TableProPluginKit
//

import Foundation

public enum SQLiteIndexCatalog {
    public static let lexicalFeatures: SQLLexicalFeatures = [
        .backtickQuotes, .bracketQuotedIdentifiers, .parenthesizedParameterNames,
    ]

    private static let expressionColumnId = -2

    public static func indexesQuery(table: String) -> String {
        """
        SELECT il.name, il."unique", il.origin, ix.cid, ix.name, m.sql
        FROM pragma_index_list('\(SQLiteMasterQueries.escapeLiteral(table))') il
        LEFT JOIN pragma_index_xinfo(il.name) ix ON ix.key = 1
        LEFT JOIN sqlite_master m ON m.type = 'index' AND m.name = il.name
        ORDER BY il.seq, ix.seqno
        """
    }

    public static let schemaIndexesQuery = """
        SELECT t.name, il.name, il."unique", il.origin, ix.cid, ix.name, m.sql
        FROM sqlite_master t
        JOIN pragma_index_list(t.name) il
        LEFT JOIN pragma_index_xinfo(il.name) ix ON ix.key = 1
        LEFT JOIN sqlite_master m ON m.type = 'index' AND m.name = il.name
        WHERE t.type = 'table' AND t.name NOT LIKE 'sqlite_%'
        ORDER BY t.name, il.seq, ix.seqno
        """

    public static func indexes(fromRows rows: [[PluginCellValue]]) -> [PluginIndexInfo] {
        infos(grouping: rows.compactMap { Row($0, offset: 0) })
    }

    public static func indexesByTable(fromRows rows: [[PluginCellValue]]) -> [String: [PluginIndexInfo]] {
        var order: [String] = []
        var rowsByTable: [String: [Row]] = [:]
        for cells in rows {
            guard let table = cells.first?.asText, let row = Row(cells, offset: 1) else { continue }
            if rowsByTable[table] == nil { order.append(table) }
            rowsByTable[table, default: []].append(row)
        }
        return order.reduce(into: [:]) { result, table in
            result[table] = infos(grouping: rowsByTable[table] ?? [])
        }
    }

    public static func keyList(for index: PluginIndexDefinition, quote: (String) -> String) -> String {
        if let spelling = index.ddlMethodAndKeys?.nilIfEmpty {
            return spelling
        }
        let expressions = Set(index.expressions ?? [])
        let keys = index.columns.map { expressions.contains($0) ? $0 : quote($0) }
        return "(\(keys.joined(separator: ", ")))"
    }

    public static func createStatement(
        for index: PluginIndexDefinition,
        table: String,
        quote: (String) -> String
    ) -> String {
        let unique = index.isUnique ? "UNIQUE " : ""
        var statement = "CREATE \(unique)INDEX \(quote(index.name)) ON \(quote(table)) "
            + keyList(for: index, quote: quote)
        if let predicate = index.whereClause?.nilIfEmpty {
            statement += " WHERE \(predicate)"
        }
        return statement
    }

    private struct Row {
        let index: String
        let isUnique: Bool
        let origin: String
        let columnId: Int?
        let column: String?
        let sql: String?

        init?(_ cells: [PluginCellValue], offset: Int) {
            guard cells.count >= offset + 6, let index = cells[offset].asText else { return nil }
            self.index = index
            self.isUnique = cells[offset + 1].asText == "1"
            self.origin = cells[offset + 2].asText ?? "c"
            self.columnId = cells[offset + 3].asText.flatMap { Int($0) }
            self.column = cells[offset + 4].asText
            self.sql = cells[offset + 5].asText
        }
    }

    private struct Entry {
        let name: String
        let isUnique: Bool
        let isPrimary: Bool
        let sql: String?
        var keys: [(columnId: Int?, column: String?)]
    }

    private static func infos(grouping rows: [Row]) -> [PluginIndexInfo] {
        var entries: [Entry] = []
        var positions: [String: Int] = [:]
        for row in rows {
            let key = (columnId: row.columnId, column: row.column)
            let hasKey = row.columnId != nil
            if let position = positions[row.index] {
                if hasKey { entries[position].keys.append(key) }
                continue
            }
            positions[row.index] = entries.count
            entries.append(Entry(
                name: row.index,
                isUnique: row.isUnique,
                isPrimary: row.origin == "pk",
                sql: row.sql,
                keys: hasKey ? [key] : []
            ))
        }
        return entries.map(info).sorted { $0.isPrimary && !$1.isPrimary }
    }

    private static func info(for entry: Entry) -> PluginIndexInfo {
        let statement = entry.sql.flatMap { SQLIndexKeyList.statement($0, lexicalFeatures: lexicalFeatures) }
        let parts = statement.flatMap { $0.keyParts.count == entry.keys.count ? $0.keyParts : nil }
        var expressions: [String] = []
        let columns = entry.keys.enumerated().compactMap { offset, key -> String? in
            if let column = key.column { return column }
            guard key.columnId == expressionColumnId, let parts else { return nil }
            let expression = SQLIndexKeyList.withoutSortOrder(parts[offset], lexicalFeatures: lexicalFeatures)
            expressions.append(expression)
            return expression
        }
        return PluginIndexInfo(
            name: entry.name,
            columns: columns,
            isUnique: entry.isUnique,
            isPrimary: entry.isPrimary,
            type: "BTREE",
            whereClause: statement?.predicate,
            expressions: expressions.isEmpty ? nil : expressions,
            includedColumns: nil,
            ddlMethodAndKeys: statement.map { "(\($0.keyList))" },
            ddlWhereClause: nil,
            isValid: nil
        )
    }
}
