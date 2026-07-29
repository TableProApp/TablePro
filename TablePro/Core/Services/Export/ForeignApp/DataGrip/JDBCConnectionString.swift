//
//  JDBCConnectionString.swift
//  TablePro
//

import Foundation

enum JDBCConnectionString {
    struct Endpoint {
        let host: String
        let port: Int?
        let database: String
    }

    static func parse(url: String, subprotocol: String) -> Endpoint? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("jdbc:") else { return nil }
        let body = String(trimmed.dropFirst("jdbc:".count))

        switch subprotocol.lowercased() {
        case "sqlserver", "jtds":
            return parseSQLServer(body)
        case "oracle":
            return parseOracle(body)
        case "sqlite", "duckdb", "h2":
            return parseFilePath(body, subprotocol: subprotocol)
        case "bigquery":
            return parseBigQuery(body)
        default:
            return parseAuthority(body)
        }
    }

    // MARK: - Authority Form

    /// jdbc:<sub>://[user[:pass]@]host[:port][/database][?params]
    /// Covers MySQL, MariaDB, PostgreSQL, ClickHouse, MongoDB, Cassandra, Redis.
    private static func parseAuthority(_ body: String) -> Endpoint? {
        guard let schemeRange = body.range(of: "://") else { return nil }
        var remainder = String(body[schemeRange.upperBound...])

        remainder = stripQuery(from: remainder)
        let pathSplit = splitOnce(remainder, separator: "/")
        let authority = stripUserInfo(pathSplit.head)
        let database = pathSplit.tail ?? ""

        let firstHost = authority.components(separatedBy: ",").first ?? authority
        let (host, port) = parseHostPort(firstHost)
        guard !host.isEmpty else { return nil }
        return Endpoint(host: host, port: port, database: database)
    }

    // MARK: - SQL Server Form

    /// jdbc:sqlserver://host[\instance][:port][;prop=value;...]
    /// jdbc:jtds:sqlserver://host:port/database
    private static func parseSQLServer(_ body: String) -> Endpoint? {
        var remainder = body
        if remainder.lowercased().hasPrefix("jtds:") {
            remainder = String(remainder.dropFirst("jtds:".count))
        }
        if remainder.lowercased().hasPrefix("sqlserver:") {
            remainder = String(remainder.dropFirst("sqlserver:".count))
        }
        guard remainder.hasPrefix("//") else { return nil }
        remainder = String(remainder.dropFirst(2))

        let semicolonSplit = splitOnce(remainder, separator: ";")
        let properties = parseSemicolonProperties(semicolonSplit.tail ?? "")

        let beforeProps = semicolonSplit.head
        let slashSplit = splitOnce(beforeProps, separator: "/")
        var authority = slashSplit.head
        var database = slashSplit.tail ?? ""

        if let backslash = authority.firstIndex(of: "\\") {
            authority = String(authority[..<backslash])
        }

        let (host, port) = parseHostPort(authority)
        guard !host.isEmpty else { return nil }

        if database.isEmpty {
            database = properties["databasename"] ?? properties["database"] ?? ""
        }
        return Endpoint(host: host, port: port, database: database)
    }

    // MARK: - Oracle Form

    /// jdbc:oracle:thin:@host:port:SID
    /// jdbc:oracle:thin:@//host:port/SERVICE_NAME
    /// jdbc:oracle:thin:@host:port/SERVICE_NAME
    private static func parseOracle(_ body: String) -> Endpoint? {
        guard let atIndex = body.firstIndex(of: "@") else { return nil }
        var descriptor = String(body[body.index(after: atIndex)...])
        descriptor = stripQuery(from: descriptor)

        if descriptor.hasPrefix("//") {
            descriptor = String(descriptor.dropFirst(2))
            let slashSplit = splitOnce(descriptor, separator: "/")
            let (host, port) = parseHostPort(slashSplit.head)
            guard !host.isEmpty else { return nil }
            return Endpoint(host: host, port: port, database: slashSplit.tail ?? "")
        }

        let parts = descriptor.components(separatedBy: ":")
        guard parts.count >= 2, !parts[0].isEmpty else {
            let slashSplit = splitOnce(descriptor, separator: "/")
            let (host, port) = parseHostPort(slashSplit.head)
            guard !host.isEmpty else { return nil }
            return Endpoint(host: host, port: port, database: slashSplit.tail ?? "")
        }

        let host = parts[0]
        let portAndRest = parts[1]
        let slashSplit = splitOnce(portAndRest, separator: "/")
        let port = Int(slashSplit.head)

        if let serviceName = slashSplit.tail {
            return Endpoint(host: host, port: port, database: serviceName)
        }
        let sid = parts.count >= 3 ? parts[2] : ""
        return Endpoint(host: host, port: port, database: sid)
    }

    // MARK: - File Form

    /// jdbc:sqlite:/path/to/file.db, jdbc:duckdb:/path/to/file.duckdb
    private static func parseFilePath(_ body: String, subprotocol: String) -> Endpoint? {
        guard body.lowercased().hasPrefix(subprotocol.lowercased() + ":") else {
            return Endpoint(host: "", port: nil, database: stripQuery(from: body))
        }
        var path = String(body.dropFirst(subprotocol.count + 1))
        path = stripQuery(from: path)
        return Endpoint(host: "", port: nil, database: path)
    }

    // MARK: - BigQuery Form

    /// jdbc:bigquery://https://www.googleapis.com/bigquery/v2;ProjectId=my-project;...
    private static func parseBigQuery(_ body: String) -> Endpoint? {
        guard body.hasPrefix("//") else { return nil }
        let remainder = String(body.dropFirst(2))
        let semicolonSplit = splitOnce(remainder, separator: ";")
        let properties = parseSemicolonProperties(semicolonSplit.tail ?? "")
        let project = properties["projectid"] ?? properties["project"] ?? ""
        return Endpoint(host: semicolonSplit.head, port: nil, database: project)
    }

    // MARK: - Helpers

    private static func parseHostPort(_ authority: String) -> (host: String, port: Int?) {
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else {
                return (authority, nil)
            }
            let host = String(authority[authority.index(after: authority.startIndex)..<closing])
            let after = authority[authority.index(after: closing)...]
            if after.hasPrefix(":") {
                return (host, Int(after.dropFirst()))
            }
            return (host, nil)
        }

        guard let colon = authority.lastIndex(of: ":") else {
            return (authority, nil)
        }
        let host = String(authority[..<colon])
        let port = Int(authority[authority.index(after: colon)...])
        return (host, port)
    }

    private static func stripUserInfo(_ authority: String) -> String {
        guard let atIndex = authority.lastIndex(of: "@") else { return authority }
        return String(authority[authority.index(after: atIndex)...])
    }

    private static func stripQuery(from value: String) -> String {
        if let question = value.firstIndex(of: "?") {
            return String(value[..<question])
        }
        return value
    }

    private static func splitOnce(_ value: String, separator: Character) -> (head: String, tail: String?) {
        guard let index = value.firstIndex(of: separator) else { return (value, nil) }
        return (String(value[..<index]), String(value[value.index(after: index)...]))
    }

    private static func parseSemicolonProperties(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.components(separatedBy: ";") where !pair.isEmpty {
            let kv = splitOnce(pair, separator: "=")
            guard let rawValue = kv.tail else { continue }
            result[kv.head.lowercased().trimmingCharacters(in: .whitespaces)] = rawValue
        }
        return result
    }
}
