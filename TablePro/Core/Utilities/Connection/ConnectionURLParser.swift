//
//  ConnectionURLParser.swift
//  TablePro
//

import Foundation

struct ParsedConnectionURL {
    let type: DatabaseType
    let host: String
    let port: Int?
    let database: String
    let username: String
    let password: String
    let sslMode: SSLMode?
    let authSource: String?
    let sshHost: String?
    let sshPort: Int?
    let sshUsername: String?
    let usePrivateKey: Bool?
    let useSSHAgent: Bool?
    let agentSocket: String?
    let connectionName: String?
    let redisDatabase: Int?
    let statusColor: String?
    let envTag: String?
    let schema: String?
    let tableName: String?
    let isView: Bool
    let filterColumn: String?
    let filterOperation: String?
    let filterValue: String?
    let filterCondition: String?
    let oracleServiceName: String?

    var suggestedName: String {
        if let connectionName, !connectionName.isEmpty {
            return connectionName
        }
        let typeName = type.rawValue
        let displayDatabase = database.isEmpty ? (oracleServiceName ?? "") : database
        if !displayDatabase.isEmpty {
            return "\(typeName) \(host)/\(displayDatabase)"
        }
        if !host.isEmpty {
            return "\(typeName) \(host)"
        }
        return typeName
    }
}

enum ConnectionURLParseError: Error, LocalizedError, Equatable {
    case emptyString
    case invalidURL
    case unsupportedScheme(String)
    case missingHost

    var errorDescription: String? {
        switch self {
        case .emptyString:
            return String(localized: "Connection URL cannot be empty")
        case .invalidURL:
            return String(localized: "Invalid connection URL format")
        case .unsupportedScheme(let scheme):
            return String(localized: "Unsupported database scheme: \(scheme)")
        case .missingHost:
            return String(localized: "Connection URL must include a host")
        }
    }
}

struct ConnectionURLParser {
    static func parse(_ urlString: String) -> Result<ParsedConnectionURL, ConnectionURLParseError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyString)
        }

        guard let schemeEnd = trimmed.range(of: "://") else {
            return .failure(.invalidURL)
        }

        var scheme = trimmed[trimmed.startIndex..<schemeEnd.lowerBound].lowercased()

        var isSSH = false
        if scheme.hasSuffix("+ssh") {
            isSSH = true
            scheme = String(scheme.dropLast(4))
        }

        let dbType: DatabaseType
        switch scheme {
        case "postgresql", "postgres":
            dbType = .postgresql
        case "redshift":
            dbType = .redshift
        case "mysql":
            dbType = .mysql
        case "mariadb":
            dbType = .mariadb
        case "sqlite":
            dbType = .sqlite
        case "mongodb", "mongodb+srv":
            dbType = .mongodb
        case "redis", "rediss":
            dbType = .redis
        case "sqlserver", "mssql", "jdbc:sqlserver":
            dbType = .mssql
        case "oracle", "jdbc:oracle:thin":
            dbType = .oracle
        case "clickhouse", "ch":
            dbType = .clickhouse
        case "cassandra", "cql":
            dbType = .cassandra
        case "scylladb", "scylla":
            dbType = .scylladb
        default:
            if let resolvedType = PluginMetadataRegistry.shared.databaseType(forUrlScheme: scheme) {
                dbType = resolvedType
            } else {
                return .failure(.unsupportedScheme(scheme))
            }
        }

        if dbType == .sqlite {
            let path = String(trimmed[schemeEnd.upperBound...])
            return .success(ParsedConnectionURL(
                type: .sqlite,
                host: "",
                port: nil,
                database: path,
                username: "",
                password: "",
                sslMode: nil,
                authSource: nil,
                sshHost: nil,
                sshPort: nil,
                sshUsername: nil,
                usePrivateKey: nil,
                useSSHAgent: nil,
                agentSocket: nil,
                connectionName: nil,
                redisDatabase: nil,
                statusColor: nil,
                envTag: nil,
                schema: nil,
                tableName: nil,
                isView: false,
                filterColumn: nil,
                filterOperation: nil,
                filterValue: nil,
                filterCondition: nil,
                oracleServiceName: nil
            ))
        }

        if isSSH {
            return parseSSHURL(trimmed, schemeEnd: schemeEnd, dbType: dbType)
        }

        let httpURL = "http://" + String(trimmed[schemeEnd.upperBound...])
        guard let components = URLComponents(string: httpURL) else {
            return .failure(.invalidURL)
        }

        guard let host = components.host, !host.isEmpty else {
            return .failure(.missingHost)
        }

        let rawPort = components.port
        let port = (rawPort == dbType.defaultPort) ? nil : rawPort
        let username = components.percentEncodedUser.flatMap {
            $0.removingPercentEncoding
        } ?? ""
        let password = components.percentEncodedPassword.flatMap {
            $0.removingPercentEncoding
        } ?? ""

        var database = components.path
        if database.hasPrefix("/") {
            database = String(database.dropFirst())
        }

        let ext = parseQueryItems(components.queryItems)

        var sslMode = ext.sslMode
        // Redis-specific: parse database index from path and handle TLS scheme
        var redisDatabase: Int?
        if dbType == .redis {
            if !database.isEmpty {
                redisDatabase = Int(database)
                database = ""
            }
            if scheme == "rediss" {
                sslMode = sslMode ?? .required
            }
        }

        // Oracle-specific: path component is the service name, not the database name
        var oracleServiceName: String?
        if dbType == .oracle && !database.isEmpty {
            oracleServiceName = database
            database = ""
        }

        return .success(ParsedConnectionURL(
            type: dbType,
            host: host,
            port: port,
            database: database,
            username: username,
            password: password,
            sslMode: sslMode,
            authSource: ext.authSource,
            sshHost: nil,
            sshPort: nil,
            sshUsername: nil,
            usePrivateKey: nil,
            useSSHAgent: nil,
            agentSocket: nil,
            connectionName: ext.connectionName,
            redisDatabase: redisDatabase,
            statusColor: ext.statusColor,
            envTag: ext.envTag,
            schema: ext.schema,
            tableName: ext.tableName,
            isView: ext.isView,
            filterColumn: ext.filterColumn,
            filterOperation: ext.filterOperation,
            filterValue: ext.filterValue,
            filterCondition: ext.filterCondition,
            oracleServiceName: oracleServiceName
        ))
    }

    // SSH URL format: scheme+ssh://ssh_user@ssh_host:ssh_port/db_user:db_pass@db_host:db_port/db_name?params
    // URLComponents can't handle two user@host segments, so we parse manually.
    private static func parseSSHURL(
        _ urlString: String,
        schemeEnd: Range<String.Index>,
        dbType: DatabaseType
    ) -> Result<ParsedConnectionURL, ConnectionURLParseError> {
        let afterScheme = String(urlString[schemeEnd.upperBound...])

        var mainPart = afterScheme
        var queryString: String?
        if let questionIndex = afterScheme.firstIndex(of: "?") {
            mainPart = String(afterScheme[afterScheme.startIndex..<questionIndex])
            queryString = String(afterScheme[afterScheme.index(after: questionIndex)...])
        }

        guard let firstSlash = mainPart.firstIndex(of: "/") else {
            return .failure(.invalidURL)
        }

        let sshPart = String(mainPart[mainPart.startIndex..<firstSlash])
        let dbPart = String(mainPart[mainPart.index(after: firstSlash)...])

        var sshUsername: String?
        var sshHostPort: String
        if let atIndex = sshPart.firstIndex(of: "@") {
            sshUsername = String(sshPart[sshPart.startIndex..<atIndex])
                .removingPercentEncoding
            sshHostPort = String(sshPart[sshPart.index(after: atIndex)...])
        } else {
            sshHostPort = sshPart
        }

        guard !sshHostPort.isEmpty else {
            return .failure(.missingHost)
        }

        var sshHost: String
        var sshPort: Int?
        if let (h, p) = parseHostPort(sshHostPort) {
            sshHost = h
            sshPort = p
        } else {
            sshHost = sshHostPort
        }

        var dbUsername = ""
        var dbPassword = ""
        var dbHostPort = ""
        var database = ""

        if let atIndex = dbPart.lastIndex(of: "@") {
            let credentials = String(dbPart[dbPart.startIndex..<atIndex])
            let afterAt = String(dbPart[dbPart.index(after: atIndex)...])

            if let colonIndex = credentials.firstIndex(of: ":") {
                dbUsername = String(credentials[credentials.startIndex..<colonIndex])
                    .removingPercentEncoding ?? ""
                dbPassword = String(credentials[credentials.index(after: colonIndex)...])
                    .removingPercentEncoding ?? ""
            } else {
                dbUsername = credentials.removingPercentEncoding ?? credentials
            }

            if let slashIndex = afterAt.firstIndex(of: "/") {
                dbHostPort = String(afterAt[afterAt.startIndex..<slashIndex])
                database = String(afterAt[afterAt.index(after: slashIndex)...])
            } else {
                dbHostPort = afterAt
            }
        } else {
            if let slashIndex = dbPart.firstIndex(of: "/") {
                dbHostPort = String(dbPart[dbPart.startIndex..<slashIndex])
                database = String(dbPart[dbPart.index(after: slashIndex)...])
            } else {
                dbHostPort = dbPart
            }
        }

        var host: String
        var port: Int?
        if let (h, p) = parseHostPort(dbHostPort) {
            host = h
            port = (p == dbType.defaultPort) ? nil : p
        } else {
            host = dbHostPort
        }

        if host.isEmpty {
            host = "127.0.0.1"
        }

        let ext = parseSSHQueryString(queryString)

        // Oracle-specific: path component is the service name, not the database name
        var oracleServiceName: String?
        if dbType == .oracle && !database.isEmpty {
            oracleServiceName = database
            database = ""
        }

        return .success(ParsedConnectionURL(
            type: dbType,
            host: host,
            port: port,
            database: database,
            username: dbUsername,
            password: dbPassword,
            sslMode: ext.sslMode,
            authSource: ext.authSource,
            sshHost: sshHost,
            sshPort: sshPort,
            sshUsername: sshUsername,
            usePrivateKey: ext.usePrivateKey,
            useSSHAgent: ext.useSSHAgent,
            agentSocket: ext.agentSocket,
            connectionName: ext.connectionName,
            redisDatabase: nil,
            statusColor: ext.statusColor,
            envTag: ext.envTag,
            schema: ext.schema,
            tableName: ext.tableName,
            isView: ext.isView,
            filterColumn: ext.filterColumn,
            filterOperation: ext.filterOperation,
            filterValue: ext.filterValue,
            filterCondition: ext.filterCondition,
            oracleServiceName: oracleServiceName
        ))
    }

    // MARK: - Query Parameter Helpers

    private struct ExtendedParams {
        var sslMode: SSLMode?
        var authSource: String?
        var connectionName: String?
        var usePrivateKey: Bool?
        var useSSHAgent: Bool?
        var agentSocket: String?
        var statusColor: String?
        var envTag: String?
        var schema: String?
        var tableName: String?
        var isView = false
        var filterColumn: String?
        var filterOperation: String?
        var filterValue: String?
        var filterCondition: String?
    }

    private static func parseQueryItems(_ queryItems: [URLQueryItem]?) -> ExtendedParams {
        var ext = ExtendedParams()
        guard let queryItems else { return ext }
        for item in queryItems {
            guard let value = item.value, !value.isEmpty else { continue }
            applyQueryParam(key: item.name, value: value, to: &ext)
        }
        return ext
    }

    private static func parseSSHQueryString(_ queryString: String?) -> ExtendedParams {
        var ext = ExtendedParams()
        guard let queryString else { return ext }
        let params = queryString.split(separator: "&", omittingEmptySubsequences: true)
        for param in params {
            let parts = param.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : nil
            guard let value else { continue }
            if String(key) == "usePrivateKey" {
                ext.usePrivateKey = value.lowercased() == "true"
                continue
            }
            if String(key) == "useSSHAgent" {
                ext.useSSHAgent = value.lowercased() == "true"
                continue
            }
            if String(key) == "agentSocket" {
                ext.agentSocket = value.removingPercentEncoding ?? value
                continue
            }
            applyQueryParam(key: String(key), value: value, to: &ext)
        }
        return ext
    }

    private static func applyQueryParam(key: String, value: String, to ext: inout ExtendedParams) {
        switch key {
        case "sslmode":
            ext.sslMode = parseSSLMode(value)
        case "authSource", "authsource":
            ext.authSource = value
        case "statusColor", "statuscolor":
            ext.statusColor = value
        case "env":
            ext.envTag = value.removingPercentEncoding ?? value
        case "schema":
            ext.schema = value
        case "table":
            ext.tableName = value.replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? value
        case "name":
            ext.connectionName = value.replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? value
        case "view":
            ext.tableName = value.replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? value
            ext.isView = true
        case "column":
            ext.filterColumn = value
        case "operation", "operator":
            ext.filterOperation = value
        case "value":
            ext.filterValue = value.replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? value
        case "condition", "raw", "query":
            ext.filterCondition = value.replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? value
        case "tLSMode", "tlsmode":
            if ext.sslMode == nil, let intValue = Int(value) {
                ext.sslMode = parseTlsModeInteger(intValue)
            }
        default:
            break
        }
    }

    // MARK: - Host/Port Parsing

    /// Parse a host:port string, handling IPv6 bracket notation ([::1]:port).
    /// Returns nil if the string is empty or contains only a bare host with no port.
    private static func parseHostPort(_ hostPort: String) -> (host: String, port: Int?)? {
        guard !hostPort.isEmpty else { return nil }

        if hostPort.hasPrefix("["), let closeBracket = hostPort.firstIndex(of: "]") {
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closeBracket])
            let afterBracket = hostPort.index(after: closeBracket)
            if afterBracket < hostPort.endIndex, hostPort[afterBracket] == ":" {
                let port = Int(hostPort[hostPort.index(after: afterBracket)...])
                return (host, port)
            }
            return (host, nil)
        }

        if let colonIndex = hostPort.lastIndex(of: ":") {
            let host = String(hostPort[hostPort.startIndex..<colonIndex])
            let port = Int(hostPort[hostPort.index(after: colonIndex)...])
            return (host, port)
        }

        return (hostPort, nil)
    }

    private static func parseSSLMode(_ value: String) -> SSLMode? {
        switch value.lowercased() {
        case "disable", "disabled":
            return .disabled
        case "prefer", "preferred":
            return .preferred
        case "require", "required":
            return .required
        case "verify-ca":
            return .verifyCa
        case "verify-full", "verify-identity":
            return .verifyIdentity
        default:
            return nil
        }
    }

    private static func parseTlsModeInteger(_ value: Int) -> SSLMode? {
        switch value {
        case 0: return .disabled
        case 1: return .preferred
        case 2: return .required
        case 3: return .verifyCa
        case 4: return .verifyIdentity
        default: return nil
        }
    }

    internal static func connectionColor(fromHex hex: String) -> ConnectionColor {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let hexInt = UInt32(cleaned, radix: 16) else {
            return .none
        }

        let r = Int((hexInt >> 16) & 0xFF)
        let g = Int((hexInt >> 8) & 0xFF)
        let b = Int(hexInt & 0xFF)

        let palette: [(ConnectionColor, Int, Int, Int)] = [
            (.red, 255, 59, 48),
            (.orange, 255, 149, 0),
            (.yellow, 255, 204, 0),
            (.green, 52, 199, 89),
            (.blue, 0, 122, 255),
            (.purple, 175, 82, 222),
            (.pink, 255, 45, 85),
            (.gray, 142, 142, 147)
        ]

        var bestColor: ConnectionColor = .none
        var bestDistance = Int.max
        for (color, pr, pg, pb) in palette {
            let dr = r - pr
            let dg = g - pg
            let db = b - pb
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                bestColor = color
            }
        }

        return bestColor
    }

    internal static func tagId(fromEnvName name: String) -> UUID? {
        let tags = TagStorage.shared.loadTags()
        return tags.first(where: { $0.name.lowercased() == name.lowercased() })?.id
    }
}
