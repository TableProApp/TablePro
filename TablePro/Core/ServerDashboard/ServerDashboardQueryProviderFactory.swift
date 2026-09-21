//
//  ServerDashboardQueryProviderFactory.swift
//  TablePro
//

import Foundation

enum ServerDashboardQueryProviderFactory {
    /// Whether an engine has a dashboard, answered without building one.
    ///
    /// The toolbar and the menu bar ask this on every validation pass, and a pass can follow a
    /// keystroke. Asking `provider(for:) != nil` instead built a provider to throw away, which on
    /// PostgreSQL is an activity catalog and a metric set. Both functions read `DashboardEngine`, so
    /// the list of engines cannot drift between the question and the answer.
    static func supportsDashboard(for databaseType: DatabaseType) -> Bool {
        DashboardEngine(databaseType) != nil
    }

    static func provider(for databaseType: DatabaseType, serverVersion: String? = nil) -> ServerDashboardQueryProvider? {
        guard let engine = DashboardEngine(databaseType) else { return nil }
        switch engine {
        case .postgresql:
            return PostgreSQLDashboardProvider(
                activityCatalog: PostgreSQLActivityCatalog(serverVersion: PostgreSQLServerVersion(serverVersion)),
                metricSet: PostgreSQLDashboardMetricSet(databaseType: databaseType)
            )
        case .postgresqlCompatible:
            return PostgreSQLDashboardProvider(
                metricSet: PostgreSQLDashboardMetricSet(databaseType: databaseType)
            )
        case .mysql:
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
        }
    }
}

/// The engines that have a dashboard, and which provider each one takes.
private enum DashboardEngine {
    case postgresql
    case postgresqlCompatible
    case mysql
    case mssql
    case clickhouse
    case duckdb
    case sqlite
    case typesense

    init?(_ databaseType: DatabaseType) {
        switch databaseType {
        case .postgresql:
            self = .postgresql
        case .redshift, .cockroachdb:
            self = .postgresqlCompatible
        case .mysql, .mariadb:
            self = .mysql
        case .mssql:
            self = .mssql
        case .clickhouse:
            self = .clickhouse
        case .duckdb:
            self = .duckdb
        case .sqlite:
            self = .sqlite
        case .typesense:
            self = .typesense
        default:
            return nil
        }
    }
}
