//
//  SQLRowLimitClause.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum SQLRowLimitClause {
    internal enum Style: Equatable {
        case limit
        case offsetFetch
        case top
    }

    internal static func style(for dialect: SQLDialectDescriptor?) -> Style {
        guard let dialect else { return .limit }
        if dialect.paginationStyle == .offsetFetch { return .offsetFetch }
        if dialect.autoLimitStyle == .top { return .top }
        return .limit
    }

    internal static func select(
        columns: String,
        from source: String,
        where condition: String? = nil,
        orderBy: String? = nil,
        limit: Int? = nil,
        dialect: SQLDialectDescriptor?
    ) -> String {
        guard let limit else {
            return base(columns: columns, from: source, where: condition, top: nil) + orderClause(orderBy)
        }
        switch style(for: dialect) {
        case .limit:
            return base(columns: columns, from: source, where: condition, top: nil)
                + orderClause(orderBy) + " LIMIT \(limit)"
        case .top:
            return base(columns: columns, from: source, where: condition, top: limit) + orderClause(orderBy)
        case .offsetFetch:
            let ordering = orderBy.map { " ORDER BY \($0)" } ?? fillerOrdering(dialect)
            return base(columns: columns, from: source, where: condition, top: nil)
                + ordering + " OFFSET 0 ROWS FETCH NEXT \(limit) ROWS ONLY"
        }
    }

    internal static func select(
        columns: String,
        from source: String,
        where condition: String?,
        limit: Int?,
        driver: any PluginDatabaseDriver,
        databaseType: DatabaseType
    ) -> String {
        let unlimited = base(columns: columns, from: source, where: condition, top: nil)
        guard let limit else { return unlimited }
        if let injected = driver.injectRowLimit(unlimited, limit: limit) {
            return injected
        }
        return leadingRows(
            columns: columns,
            from: source,
            where: condition,
            limit: limit,
            dialect: PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect
        )
    }

    private static func leadingRows(
        columns: String,
        from source: String,
        where condition: String?,
        limit: Int,
        dialect: SQLDialectDescriptor?
    ) -> String {
        switch dialect?.autoLimitStyle ?? .limit {
        case .top:
            return base(columns: columns, from: source, where: condition, top: limit)
        case .fetchFirst:
            return base(columns: columns, from: source, where: condition, top: nil)
                + " FETCH FIRST \(limit) ROWS ONLY"
        case .limit:
            return base(columns: columns, from: source, where: condition, top: nil) + " LIMIT \(limit)"
        default:
            return select(columns: columns, from: source, where: condition, limit: limit, dialect: dialect)
        }
    }

    private static func base(columns: String, from source: String, where condition: String?, top: Int?) -> String {
        var sql = "SELECT "
        if let top {
            sql += "TOP \(top) "
        }
        sql += "\(columns) FROM \(source)"
        if let condition {
            sql += " WHERE \(condition)"
        }
        return sql
    }

    private static func orderClause(_ orderBy: String?) -> String {
        guard let orderBy else { return "" }
        return " ORDER BY \(orderBy)"
    }

    private static func fillerOrdering(_ dialect: SQLDialectDescriptor?) -> String {
        let filler = dialect?.offsetFetchOrderBy ?? ""
        return filler.isEmpty ? "" : " \(filler)"
    }
}
