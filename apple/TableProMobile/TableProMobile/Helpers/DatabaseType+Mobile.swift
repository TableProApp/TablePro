import Foundation
import TableProModels
import TableProPluginKit

nonisolated extension DatabaseType {
    var defaultPort: String {
        guard dialsServer else { return "" }
        switch self {
        case .mysql, .mariadb: return "3306"
        case .tidb: return "4000"
        case .databend: return "3307"
        case .oceanbase: return "2881"
        case .postgresql: return "5432"
        case .redshift: return "5439"
        case .redis: return "6379"
        case .mssql: return "1433"
        case .oracle: return "1521"
        case .clickhouse: return String(ClickHousePlugin.defaultPort)
        case .mongodb: return "27017"
        default: return "3306"
        }
    }

    // The Mac's three shapes, which its plugins declare: a server dialed by host, a file, or an API with neither.
    var connectionMode: ConnectionMode {
        switch self {
        case .sqlite, .duckdb: .fileBased
        case .cloudflareD1: .apiOnly
        default: .network
        }
    }

    var isLocalFile: Bool {
        connectionMode == .fileBased
    }

    // A server dialed by host and port, the only shape a tunnel, a TLS mode or a port applies to.
    var dialsServer: Bool {
        connectionMode == .network
    }

    var speaksSQL: Bool {
        switch self {
        case .redis, .mongodb: false
        default: true
        }
    }

    var mobileDisplayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .tidb: "TiDB"
        case .databend: "Databend"
        case .oceanbase: "OceanBase"
        case .postgresql: "PostgreSQL"
        case .redshift: "Redshift"
        case .sqlite: "SQLite"
        case .duckdb: "DuckDB"
        case .redis: "Redis"
        case .mssql: "SQL Server"
        case .oracle: "Oracle"
        default: rawValue
        }
    }

    static let mobileSupportedTypes: [DatabaseType] = [
        .mysql,
        .mariadb,
        .tidb,
        .oceanbase,
        .postgresql,
        .sqlite,
        .duckdb,
        .redis,
        .mssql,
        .oracle,
        .clickhouse,
        .mongodb,
        .cloudflareD1
    ]
}
