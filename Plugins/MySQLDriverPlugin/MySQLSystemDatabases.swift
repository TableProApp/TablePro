//
//  MySQLSystemDatabases.swift
//  MySQLDriverPlugin
//

import Foundation

/// The system databases each MySQL-family connection type recognises, in every spelling a server that type can
/// reach reports. The flavor comes from the server banner, so a MySQL or MariaDB connection can land on TiDB, which
/// spells `INFORMATION_SCHEMA` and `PERFORMANCE_SCHEMA` in capitals. `METRICS_SCHEMA` stays off the MySQL list
/// because MySQL lets a user create a database by that name and keep tables in it; the TiDB type lists it. A
/// capitalised `PERFORMANCE_SCHEMA` can be created on MySQL 5.7 and MariaDB, but the server then refuses every table,
/// view and routine in it, so listing it as system hides nothing a user can write.
nonisolated internal enum MySQLSystemDatabases {
    static let mysql: [String] = [
        "information_schema", "mysql", "performance_schema", "sys", "INFORMATION_SCHEMA", "PERFORMANCE_SCHEMA"
    ]

    static let tidb: [String] = [
        "INFORMATION_SCHEMA", "METRICS_SCHEMA", "PERFORMANCE_SCHEMA", "mysql", "sys",
        "information_schema", "performance_schema"
    ]

    static func names(forVariant variant: String?) -> [String] {
        switch variant {
        case MySQLServerFlavor.tidbVariant:
            return tidb
        case MySQLServerFlavor.databendVariant:
            return MySQLServerFlavor.databend.systemDatabaseNames
        case MySQLServerFlavor.oceanbaseVariant:
            return MySQLServerFlavor.oceanbase(version: nil).systemDatabaseNames
        default:
            return mysql
        }
    }
}
