//
//  DotenvConnectionExtractor+DiscreteKeys.swift
//  TablePro
//

import Foundation

extension DotenvConnectionExtractor {
    static func laravelCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        guard let connection = context.document["DB_CONNECTION"]?.lowercased(),
              let type = laravelType(connection) else {
            return nil
        }
        var fields = ScannedConnectionFields(type: type)
        guard type != .sqlite else {
            fields.database = resolveSQLitePath(
                context.document["DB_DATABASE"],
                directoryURL: context.directoryURL
            )
            return candidate(context, fields: fields, key: "DB_CONNECTION")
        }
        fields.host = context.document["DB_HOST"] ?? "127.0.0.1"
        fields.port = context.document["DB_PORT"].flatMap { Int($0) } ?? type.defaultPort
        fields.database = context.document["DB_DATABASE"] ?? ""
        fields.username = context.document["DB_USERNAME"] ?? ""
        fields.password = context.document["DB_PASSWORD"] ?? ""
        return candidate(context, fields: fields, key: "DB_CONNECTION", warnings: serviceHostWarnings(fields.host))
    }

    static func dockerRelationalCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        if let postgres = dockerPostgresCandidate(context) {
            return postgres
        }
        if let mysql = dockerMySQLCandidate(context) {
            return mysql
        }
        return dockerMSSQLCandidate(context)
    }

    static func libpqCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        let document = context.document
        guard document["PGHOST"] != nil || document["PGDATABASE"] != nil else {
            return nil
        }
        var fields = ScannedConnectionFields(type: .postgresql)
        fields.host = document["PGHOST"] ?? "127.0.0.1"
        fields.port = document["PGPORT"].flatMap { Int($0) } ?? 5_432
        fields.database = document["PGDATABASE"] ?? ""
        fields.username = document["PGUSER"] ?? ""
        fields.password = document["PGPASSWORD"] ?? ""
        return candidate(context, fields: fields, key: "PGHOST", warnings: serviceHostWarnings(fields.host))
    }

    static func redisDiscreteCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        let document = context.document
        guard document["REDIS_HOST"] != nil || document["REDIS_PASSWORD"] != nil else {
            return nil
        }
        var fields = ScannedConnectionFields(type: .redis)
        fields.host = document["REDIS_HOST"] ?? "127.0.0.1"
        fields.port = document["REDIS_PORT"].flatMap { Int($0) } ?? 6_379
        fields.username = document["REDIS_USERNAME"] ?? ""
        fields.password = document["REDIS_PASSWORD"] ?? ""
        fields.redisDatabase = document["REDIS_DB"].flatMap { Int($0) }
        return candidate(context, fields: fields, key: "REDIS_HOST", warnings: serviceHostWarnings(fields.host))
    }

    static func mongoDiscreteCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        let document = context.document
        let username = document["MONGO_INITDB_ROOT_USERNAME"] ?? document["MONGODB_INITDB_ROOT_USERNAME"]
        let password = document["MONGO_INITDB_ROOT_PASSWORD"] ?? document["MONGODB_INITDB_ROOT_PASSWORD"]
        guard username != nil || password != nil else {
            return nil
        }
        var fields = ScannedConnectionFields(type: .mongodb)
        fields.host = document["MONGO_HOST"] ?? "127.0.0.1"
        fields.port = document["MONGO_PORT"].flatMap { Int($0) } ?? 27_017
        fields.database = document["MONGO_INITDB_DATABASE"] ?? document["MONGODB_INITDB_DATABASE"] ?? ""
        fields.username = username ?? ""
        fields.password = password ?? ""
        return candidate(
            context,
            fields: fields,
            key: "MONGO_INITDB_ROOT_USERNAME",
            warnings: serviceHostWarnings(fields.host)
        )
    }

    private static func dockerPostgresCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        let document = context.document
        guard document["POSTGRES_PASSWORD"] != nil
            || document["POSTGRES_DB"] != nil
            || document["POSTGRES_USER"] != nil else {
            return nil
        }
        var fields = ScannedConnectionFields(type: .postgresql)
        fields.host = document["POSTGRES_HOST"] ?? "127.0.0.1"
        fields.port = document["POSTGRES_PORT"].flatMap { Int($0) } ?? 5_432
        fields.username = document["POSTGRES_USER"] ?? "postgres"
        fields.password = document["POSTGRES_PASSWORD"] ?? ""
        fields.database = document["POSTGRES_DB"] ?? fields.username
        var warnings = serviceHostWarnings(fields.host)
        if document["POSTGRES_HOST"] == nil || document["POSTGRES_PORT"] == nil {
            warnings.append(assumedAddressWarning)
        }
        return candidate(context, fields: fields, key: "POSTGRES_PASSWORD", warnings: warnings)
    }

    private static func dockerMySQLCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        let document = context.document
        let usesMariaDB = document["MARIADB_DATABASE"] != nil
            || document["MARIADB_USER"] != nil
            || document["MARIADB_PASSWORD"] != nil
            || document["MARIADB_ROOT_PASSWORD"] != nil
        let prefix = usesMariaDB ? "MARIADB" : "MYSQL"
        guard document["\(prefix)_DATABASE"] != nil
            || document["\(prefix)_USER"] != nil
            || document["\(prefix)_PASSWORD"] != nil
            || document["\(prefix)_ROOT_PASSWORD"] != nil else {
            return nil
        }
        var fields = ScannedConnectionFields(type: usesMariaDB ? .mariadb : .mysql)
        fields.host = document["MYSQL_HOST"] ?? "127.0.0.1"
        fields.port = document["MYSQL_TCP_PORT"].flatMap { Int($0) } ?? 3_306
        fields.database = document["\(prefix)_DATABASE"] ?? ""
        fields.username = document["\(prefix)_USER"] ?? "root"
        fields.password = document["\(prefix)_PASSWORD"] ?? document["\(prefix)_ROOT_PASSWORD"] ?? ""
        var warnings = serviceHostWarnings(fields.host)
        if document["MYSQL_HOST"] == nil {
            warnings.append(assumedAddressWarning)
        }
        return candidate(context, fields: fields, key: "\(prefix)_PASSWORD", warnings: warnings)
    }

    private static func dockerMSSQLCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        let document = context.document
        guard let password = document["MSSQL_SA_PASSWORD"] ?? document["SA_PASSWORD"] else {
            return nil
        }
        var fields = ScannedConnectionFields(type: .mssql)
        fields.host = "127.0.0.1"
        fields.port = document["MSSQL_TCP_PORT"].flatMap { Int($0) } ?? 1_433
        fields.database = document["MSSQL_DB"] ?? ""
        fields.username = document["MSSQL_USER"] ?? "sa"
        fields.password = password
        return candidate(context, fields: fields, key: "MSSQL_SA_PASSWORD", warnings: [assumedAddressWarning])
    }

    private static func laravelType(_ connection: String) -> DatabaseType? {
        switch connection {
        case "sqlite":
            return .sqlite
        case "mysql":
            return .mysql
        case "mariadb":
            return .mariadb
        case "pgsql":
            return .postgresql
        case "sqlsrv":
            return .mssql
        default:
            return nil
        }
    }

    static func resolveSQLitePath(_ value: String?, directoryURL: URL) -> String {
        guard let value, !value.isEmpty else {
            return directoryURL.appendingPathComponent("database/database.sqlite").path
        }
        guard value != ":memory:" else {
            return value
        }
        guard !value.hasPrefix("/") else {
            return value
        }
        return directoryURL.appendingPathComponent(value).standardizedFileURL.path
    }

    private static var assumedAddressWarning: String {
        String(localized: "Host and port assumed")
    }

    private static func serviceHostWarnings(_ host: String) -> [String] {
        let serviceNames: Set<String> = [
            "db", "database", "postgres", "postgresql", "mysql",
            "mariadb", "mongo", "mongodb", "redis", "mssql", "pgsql",
        ]
        guard serviceNames.contains(host.lowercased()) else {
            return []
        }
        return [String(localized: "Container service name, may be unreachable")]
    }
}
