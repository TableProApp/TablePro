//
//  ExplainPlanFormatDefaults.swift
//  TablePro
//
//  The plan format the app assumes for a database type when the driver's declared variant
//  does not name one. A plugin built before ExplainVariant carried a format still reports
//  .plainText, so without this table its plans would render as raw text until it is rebuilt.
//

import Foundation
import TableProPluginKit

enum ExplainPlanFormatDefaults {
    static func format(for databaseType: DatabaseType) -> ExplainPlanFormat {
        switch databaseType {
        case .postgresql, .redshift, .pglite:
            return .postgresJson
        case .mysql, .mariadb:
            return .mysqlComposite
        case .sqlite, .cloudflareD1, .libsql, .turso:
            return .sqliteQueryPlan
        case .cockroachdb:
            return .cockroachText
        case .clickhouse, .duckdb:
            return .indentedText
        case .dameng:
            return .damengText
        default:
            return .plainText
        }
    }
}
