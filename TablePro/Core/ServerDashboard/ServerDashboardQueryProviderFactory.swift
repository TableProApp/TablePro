//
//  ServerDashboardQueryProviderFactory.swift
//  TablePro
//

import Foundation

enum ServerDashboardQueryProviderFactory {
    static func provider(for databaseType: DatabaseType) -> ServerDashboardQueryProvider? {
        switch databaseType {
        case .postgresql, .redshift:
            return PostgreSQLDashboardProvider()
        case .mysql, .mariadb:
            return MySQLDashboardProvider()
        case .mssql:
            return MSSQLDashboardProvider()
        case .clickhouse:
            return ClickHouseDashboardProvider()
        case .duckdb:
            return DuckDBDashboardProvider()
        case .sqlite:
            return SQLiteDashboardProvider()
        default:
            return nil
        }
    }
}
