//
//  JoinQuerySQLWriter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct JoinQuerySQLWriter {
    internal let graph: JoinGraph
    internal let columnTypes: [String: [String: ColumnType]]
    internal let dialect: SQLDialectDescriptor
    internal let databaseType: DatabaseType
    internal let schema: String?
    internal let quote: (String) -> String

    internal func sql(for draft: JoinQueryDraft) -> String? {
        guard let first = draft.tables.first else { return nil }

        let selected = draft.tables.flatMap { table in
            table.selectedColumns.map { column(table.name, $0) }
        }
        var lines = [
            "SELECT \(selected.isEmpty ? "*" : selected.joined(separator: ", "))",
            "FROM \(source(first.name))"
        ]
        for table in draft.tables.dropFirst() {
            guard let condition = table.condition else {
                lines.append("CROSS JOIN \(source(table.name))")
                continue
            }
            lines.append("\(table.kind.keyword) \(source(table.name)) ON \(onClause(condition))")
        }

        let conditions = draft.filters.compactMap(condition(for:))
        if !conditions.isEmpty {
            lines.append("WHERE \(conditions.joined(separator: " AND "))")
        }
        return lines.joined(separator: "\n")
    }

    private func source(_ table: String) -> String {
        guard let schema else { return quote(table) }
        return "\(quote(schema)).\(quote(table))"
    }

    private func column(_ table: String, _ column: String) -> String {
        "\(quote(table)).\(quote(column))"
    }

    private func onClause(_ relationship: JoinRelationship) -> String {
        relationship.columnPairs
            .map { "\(column(relationship.childTable, $0.child)) = \(column(relationship.parentTable, $0.parent))" }
            .joined(separator: " AND ")
    }

    // The filter bar's own generator, so a value is typed and escaped exactly as a table filter's is.
    private func condition(for filter: JoinFilter) -> String? {
        let table = filter.column.table
        let types = columnTypes[table] ?? [:]
        let names = graph.columns(of: table).filter { types[$0] != nil }
        let quote = self.quote
        let generator = FilterSQLGenerator(
            dialect: dialect,
            columns: names,
            columnTypes: names.compactMap { types[$0] },
            quoteIdentifier: { "\(quote(table)).\(quote($0))" },
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType),
            databaseType: databaseType
        )
        return generator.generateCondition(from: filter.tableFilter)
    }
}
