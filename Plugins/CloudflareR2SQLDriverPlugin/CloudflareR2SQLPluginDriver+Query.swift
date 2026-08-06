//
//  CloudflareR2SQLPluginDriver+Query.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProR2SQLCore

extension CloudflareR2SQLPluginDriver {
    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let result = try await run(sql: query)
        return Self.pluginResult(result, executionTime: Date().timeIntervalSince(started))
    }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table,
            schema: currentSchema,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset
        )
    }

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        guard let namespace = resolveNamespace(schema) else { return nil }
        return R2SQLQueryBuilder.browseQuery(
            namespace: namespace,
            table: table,
            columns: columns,
            sortColumns: Self.sortColumns(sortColumns, in: columns),
            limit: limit
        )
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table,
            schema: currentSchema,
            filters: filters,
            logicMode: logicMode,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        guard let namespace = resolveNamespace(schema) else { return nil }
        return R2SQLQueryBuilder.filteredQuery(
            namespace: namespace,
            table: table,
            filters: filters.map { R2SQLFilter(column: $0.column, op: $0.op, value: $0.value) },
            matchAll: logicMode.lowercased() != "or",
            columns: columns,
            sortColumns: Self.sortColumns(sortColumns, in: columns),
            limit: limit
        )
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) async throws -> Int? {
        guard let namespace = resolveNamespace(schema) else { return nil }
        let sql = R2SQLQueryBuilder.countQuery(
            namespace: namespace,
            table: table,
            filters: filters.map { R2SQLFilter(column: $0.column, op: $0.op, value: $0.value) },
            matchAll: logicMode.lowercased() != "or"
        )
        let result = try await run(sql: sql)
        return R2SQLRowMapper.firstColumnStrings(result).first.flatMap(Int.init)
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        guard let namespace = resolveNamespace(schema) else { return nil }
        return R2SQLQueryBuilder.browseQuery(
            namespace: namespace,
            table: table,
            limit: R2SQLLimits.maxLimit
        )
    }

    func quoteIdentifier(_ name: String) -> String {
        R2SQLLiteral.quoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        R2SQLLiteral.escapeStringLiteral(value)
    }

    static func sortColumns(
        _ sortColumns: [(columnIndex: Int, ascending: Bool)],
        in columns: [String]
    ) -> [R2SQLSortColumn] {
        sortColumns.compactMap { sort in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            return R2SQLSortColumn(name: columns[sort.columnIndex], ascending: sort.ascending)
        }
    }

    static func pluginResult(_ result: R2SQLResult, executionTime: TimeInterval) -> PluginQueryResult {
        let mapped = R2SQLRowMapper.map(result)
        return PluginQueryResult(
            columns: mapped.columns,
            columnTypeNames: mapped.columnTypeNames,
            rows: mapped.rows.map { $0.map(cellValue) },
            rowsAffected: 0,
            executionTime: executionTime,
            isTruncated: false,
            statusMessage: nil
        )
    }

    static func cellValue(_ value: R2SQLValue) -> PluginCellValue {
        switch value {
        case .null:
            return .null
        case .text(let text):
            return .text(text)
        case .bytes(let bytes):
            return .bytes(Data(bytes))
        }
    }
}
