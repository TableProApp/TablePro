import Foundation

enum RDSEngineCatalog {
    private static let exactTypes: [String: DatabaseType] = [
        "mysql": .mysql,
        "aurora": .mysql,
        "aurora-mysql": .mysql,
        "mariadb": .mariadb,
        "postgres": .postgresql,
        "aurora-postgresql": .postgresql
    ]

    private static let prefixedTypes: [(prefix: String, type: DatabaseType)] = [
        ("oracle-", .oracle),
        ("custom-oracle-", .oracle),
        ("sqlserver-", .mssql),
        ("custom-sqlserver-", .mssql)
    ]

    private static let defaultPorts: [String: Int] = [
        DatabaseType.mysql.rawValue: 3_306,
        DatabaseType.mariadb.rawValue: 3_306,
        DatabaseType.postgresql.rawValue: 5_432,
        DatabaseType.oracle.rawValue: 1_521,
        DatabaseType.mssql.rawValue: 1_433
    ]

    static func databaseType(forEngine engine: String) -> DatabaseType? {
        let normalized = engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let type = exactTypes[normalized] {
            return type
        }
        for entry in prefixedTypes where normalized.hasPrefix(entry.prefix) {
            return entry.type
        }
        return nil
    }

    static func defaultPort(forEngine engine: String) -> Int? {
        guard let type = databaseType(forEngine: engine) else { return nil }
        return defaultPorts[type.rawValue]
    }

    static func displayName(forEngine engine: String) -> String {
        let normalized = engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "aurora", "aurora-mysql":
            return "Aurora MySQL"
        case "aurora-postgresql":
            return "Aurora PostgreSQL"
        case "postgres":
            return "PostgreSQL"
        case "mysql":
            return "MySQL"
        case "mariadb":
            return "MariaDB"
        default:
            return engine
        }
    }
}
