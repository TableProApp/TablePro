//
//  DatabaseTypeStyle.swift
//  TableProWidget
//

import SwiftUI

enum DatabaseTypeStyle {
    static func iconName(for type: String) -> String {
        switch type {
        case "MySQL": return "mysql-icon"
        case "MariaDB": return "mariadb-icon"
        case "PostgreSQL": return "postgresql-icon"
        case "Redshift": return "redshift-icon"
        case "SQLite": return "sqlite-icon"
        case "Redis": return "redis-icon"
        case "MongoDB": return "mongodb-icon"
        case "ClickHouse": return "clickhouse-icon"
        case "SQL Server": return "mssql-icon"
        case "Oracle": return "oracle-icon"
        case "DuckDB": return "duckdb-icon"
        case "Cassandra": return "cassandra-icon"
        case "etcd": return "etcd-icon"
        case "Cloudflare D1": return "cloudflare-d1-icon"
        case "DynamoDB": return "dynamodb-icon"
        case "BigQuery": return "bigquery-icon"
        default: return "externaldrive"
        }
    }

    @ViewBuilder
    static func iconImage(for type: String, size: CGFloat) -> some View {
        let name = iconName(for: type)
        if name.hasSuffix("-icon") {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .font(.system(size: size))
        }
    }

    static func iconColor(for type: String) -> Color {
        switch type {
        case "MySQL", "MariaDB": return .orange
        case "PostgreSQL", "Redshift": return .blue
        case "SQLite": return .green
        case "Redis": return .red
        case "MongoDB": return .green
        case "ClickHouse": return .yellow
        case "SQL Server": return .indigo
        default: return .gray
        }
    }
}
