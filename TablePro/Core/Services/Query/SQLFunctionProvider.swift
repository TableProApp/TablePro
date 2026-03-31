//
//  SQLFunctionProvider.swift
//  TablePro

internal enum SQLFunctionProvider {
    internal struct SQLFunction {
        let label: String
        let expression: String
    }

    static func functions(for databaseType: DatabaseType) -> [SQLFunction] {
        if databaseType == .mysql || databaseType == .mariadb {
            return [
                SQLFunction(label: "NOW()", expression: "NOW()"),
                SQLFunction(label: "CURRENT_TIMESTAMP()", expression: "CURRENT_TIMESTAMP()"),
                SQLFunction(label: "CURDATE()", expression: "CURDATE()"),
                SQLFunction(label: "CURTIME()", expression: "CURTIME()"),
                SQLFunction(label: "UTC_TIMESTAMP()", expression: "UTC_TIMESTAMP()"),
                SQLFunction(label: "UUID()", expression: "UUID()")
            ]
        } else if databaseType == .postgresql || databaseType == .redshift {
            return [
                SQLFunction(label: "now()", expression: "now()"),
                SQLFunction(label: "CURRENT_TIMESTAMP", expression: "CURRENT_TIMESTAMP"),
                SQLFunction(label: "CURRENT_DATE", expression: "CURRENT_DATE"),
                SQLFunction(label: "CURRENT_TIME", expression: "CURRENT_TIME"),
                SQLFunction(label: "gen_random_uuid()", expression: "gen_random_uuid()")
            ]
        } else if databaseType == .sqlite || databaseType == .duckdb || databaseType == .cloudflareD1 {
            return [
                SQLFunction(label: "datetime('now')", expression: "datetime('now')"),
                SQLFunction(label: "date('now')", expression: "date('now')"),
                SQLFunction(label: "time('now')", expression: "time('now')"),
                SQLFunction(label: "datetime('now','localtime')", expression: "datetime('now','localtime')")
            ]
        } else if databaseType == .mssql {
            return [
                SQLFunction(label: "GETDATE()", expression: "GETDATE()"),
                SQLFunction(label: "GETUTCDATE()", expression: "GETUTCDATE()"),
                SQLFunction(label: "SYSDATETIME()", expression: "SYSDATETIME()"),
                SQLFunction(label: "NEWID()", expression: "NEWID()")
            ]
        } else if databaseType == .clickhouse {
            return [
                SQLFunction(label: "now()", expression: "now()"),
                SQLFunction(label: "today()", expression: "today()"),
                SQLFunction(label: "yesterday()", expression: "yesterday()"),
                SQLFunction(label: "generateUUIDv4()", expression: "generateUUIDv4()")
            ]
        } else {
            return [
                SQLFunction(label: "CURRENT_TIMESTAMP", expression: "CURRENT_TIMESTAMP"),
                SQLFunction(label: "CURRENT_DATE", expression: "CURRENT_DATE"),
                SQLFunction(label: "CURRENT_TIME", expression: "CURRENT_TIME")
            ]
        }
    }
}
