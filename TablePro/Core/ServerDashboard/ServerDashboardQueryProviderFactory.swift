//
//  ServerDashboardQueryProviderFactory.swift
//  TablePro
//

import Foundation

enum ServerDashboardQueryProviderFactory {
    static func provider(for databaseType: DatabaseType, serverVersion: String? = nil) -> ServerDashboardQueryProvider? {
        switch databaseType {
        case .postgresql:
            return PostgreSQLDashboardProvider(
                activityCatalog: PostgreSQLActivityCatalog(serverVersion: PostgreSQLServerVersion(serverVersion)),
                metricSet: PostgreSQLDashboardMetricSet(databaseType: databaseType)
            )
        case .redshift, .cockroachdb:
            return PostgreSQLDashboardProvider(
                metricSet: PostgreSQLDashboardMetricSet(databaseType: databaseType)
            )
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
        case .typesense:
            return TypesenseDashboardProvider()
        default:
            return nil
        }
    }
}
