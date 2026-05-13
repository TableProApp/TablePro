import Foundation
import TableProModels

extension DatabaseType {
    var defaultPort: String {
        switch self {
        case .mysql, .mariadb: return "3306"
        case .postgresql: return "5432"
        case .redshift: return "5439"
        case .redis: return "6379"
        case .mssql: return "1433"
        case .sqlite: return ""
        default: return "3306"
        }
    }

    var mobileDisplayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        case .redshift: "Redshift"
        case .sqlite: "SQLite"
        case .redis: "Redis"
        case .mssql: "SQL Server"
        default: rawValue.uppercased()
        }
    }

    static let mobileSupportedTypes: [DatabaseType] = [
        .mysql,
        .mariadb,
        .postgresql,
        .sqlite,
        .redis,
        .mssql
    ]
}
