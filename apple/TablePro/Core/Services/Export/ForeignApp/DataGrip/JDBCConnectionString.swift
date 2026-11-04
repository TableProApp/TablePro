//
//  JDBCConnectionString.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum JDBCConnectionString {
    struct Endpoint {
        let host: String
        let port: Int?
        let database: String
        // The user a URL names before `@` or in its `user` parameter; its password never leaves the URL.
        let username: String?
    }

    // What a URL says about TLS. Only `sslmode`, a secure scheme and a seed list say it plainly; the
    // drivers read every other switch their own way and in combination, so a URL that uses one is unread.
    enum TLS: Equatable {
        case none
        case mode(SSLMode)
        case unread(String)
    }

    static let mongoUseSrvField = "mongoUseSrv"
    static let mongoAuthSourceField = "mongoAuthSource"

    static func parse(url: String, subprotocol: String) -> Endpoint? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // The MongoDB driver takes its own URL, which DataGrip stores with no `jdbc:` before it.
        if isNativeMongo(trimmed) {
            return parseAuthority(trimmed)
        }
        guard let body = strippingPrefix("jdbc:", from: trimmed) else { return nil }

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

    static func isNativeMongo(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return strippingPrefix("mongodb://", from: trimmed) != nil || isMongoSeedList(trimmed)
    }

    static func isMongoSeedList(_ url: String) -> Bool {
        strippingPrefix("mongodb+srv://", from: url.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // What a MongoDB URL says that the connection keeps as a driver field: a seed list, and the
    // database it signs in against.
    static func urlFields(_ url: String) -> [String: String] {
        var fields: [String: String] = [:]
        if isMongoSeedList(url) {
            fields[mongoUseSrvField] = "true"
        }
        let isMongo = isNativeMongo(url) || subprotocol(of: url).lowercased() == "mongodb"
        if isMongo, let source = queryPairs(url, separators: ["&"], semicolonStartsQuery: false)
            .last(where: { $0.key.lowercased() == "authsource" })
            .map({ percentDecoded($0.value) }), !source.isEmpty {
            fields[mongoAuthSourceField] = source
        }
        return fields
    }

    static func subprotocol(of url: String) -> String {
        guard let rest = strippingPrefix("jdbc:", from: url) else { return "" }
        return String(rest.prefix { $0 != ":" && $0 != "/" })
    }

    static func tls(of url: String) -> TLS {
        let parameters = queryPairs(url, separators: ["&", ";"])
        let switches = parameters.filter { isTLSParameter($0.key) }
        // Unread TLS names the switches, never their values: `sslpassword` holds a secret.
        if switches.contains(where: { $0.key.lowercased() != "sslmode" }) {
            return .unread(switches.map { $0.key }.joined(separator: ", "))
        }
        if let mode = switches.last {
            guard let named = namedMode(mode.value.lowercased()) else {
                return .unread(mode.value.isEmpty ? mode.key : mode.value)
            }
            return .mode(named)
        }
        return isMongoSeedList(url) || hasSecureScheme(url) ? .mode(.verifyIdentity) : .none
    }

    static func isTLSParameter(_ name: String) -> Bool {
        let key = name.lowercased()
        return key.hasPrefix("ssl") || key.hasPrefix("tls")
            || ["usessl", "requiressl", "encrypt", "trustservercertificate", "verifyservercertificate"].contains(key)
    }

    // `jdbc:clickhouse:https://` and the like: a scheme that is TLS by itself, verified by default.
    private static func hasSecureScheme(_ url: String) -> Bool {
        guard let range = url.range(of: "://") else { return false }
        let scheme = url[..<range.lowerBound].lowercased()
        return scheme.hasSuffix("https") || scheme.hasSuffix("+tls") || scheme.hasSuffix("+ssl")
    }

    private static func namedMode(_ mode: String) -> SSLMode? {
        switch mode {
        case "disable", "disabled": return .disabled
        case "allow", "prefer", "preferred": return .preferred
        // MariaDB's `trust` encrypts without checking the certificate.
        case "require", "required", "trust": return .required
        case "verify-ca", "verify_ca": return .verifyCa
        case "verify-full", "verify_full", "verify_identity": return .verifyIdentity
        default: return nil
        }
    }

    // MARK: - Authority Form

    // jdbc:<sub>://[user[:pass]@]host[:port][/database][?params], and MongoDB's own URL.
    private static func parseAuthority(_ body: String) -> Endpoint? {
        guard let schemeRange = body.range(of: "://") else { return nil }
        let remainder = stripQuery(from: String(body[schemeRange.upperBound...]))
        let pathSplit = splitOnce(remainder, separator: "/")
        let authority = stripUserInfo(pathSplit.head)

        let firstHost = authority.components(separatedBy: ",").first ?? authority
        let (host, port) = parseHostPort(firstHost)
        guard !host.isEmpty else { return nil }

        let userInfo = pathSplit.head.lastIndex(of: "@").map { String(pathSplit.head[..<$0]) }
        let infoUser = userInfo.map { percentDecoded(splitOnce($0, separator: ":").head) }
        let parameterUser = urlParameter(body, name: "user").map { percentDecoded($0) }
        let username = [infoUser, parameterUser].compactMap { $0 }.first { !$0.isEmpty }
        // A database name escapes a space or a slash, and the drivers take the name as written.
        let database = percentDecoded(pathSplit.tail ?? "")
        return Endpoint(host: host, port: port, database: database, username: username)
    }

    // MARK: - SQL Server Form

    // jdbc:sqlserver://host[\instance][:port][;prop=value;...] and jdbc:jtds:sqlserver://host:port/database
    private static func parseSQLServer(_ body: String) -> Endpoint? {
        var remainder = body
        if let rest = strippingPrefix("jtds:", from: remainder) {
            remainder = rest
        }
        if let rest = strippingPrefix("sqlserver:", from: remainder) {
            remainder = rest
        }
        guard remainder.hasPrefix("//") else { return nil }
        remainder = String(remainder.dropFirst(2))

        let semicolonSplit = splitOnce(remainder, separator: ";")
        let properties = parseSemicolonProperties(semicolonSplit.tail ?? "")
        let slashSplit = splitOnce(semicolonSplit.head, separator: "/")
        var database = slashSplit.tail ?? ""

        // `host\instance:port` names its port after the instance.
        let host: String
        let port: Int?
        let instanceSplit = splitOnce(slashSplit.head, separator: "\\")
        if let instance = instanceSplit.tail {
            host = instanceSplit.head
            port = instance.lastIndex(of: ":").flatMap { Int(instance[instance.index(after: $0)...]) }
        } else {
            (host, port) = parseHostPort(slashSplit.head)
        }
        guard !host.isEmpty else { return nil }

        if database.isEmpty {
            database = properties["databasename"] ?? properties["database"] ?? ""
        }
        let username = urlParameter(body, name: "user").flatMap { $0.isEmpty ? nil : $0 }
        return Endpoint(host: host, port: port, database: database, username: username)
    }

    // MARK: - Oracle Form

    // jdbc:oracle:thin:@host:port:SID, @//host:port/SERVICE_NAME and @host:port/SERVICE_NAME
    private static func parseOracle(_ body: String) -> Endpoint? {
        guard let atIndex = body.firstIndex(of: "@") else { return nil }
        var descriptor = String(body[body.index(after: atIndex)...])
        descriptor = stripQuery(from: descriptor)

        if descriptor.hasPrefix("//") {
            return hostPortPath(String(descriptor.dropFirst(2)))
        }

        let parts = descriptor.components(separatedBy: ":")
        guard parts.count >= 2, !parts[0].isEmpty else {
            return hostPortPath(descriptor)
        }

        let slashSplit = splitOnce(parts[1], separator: "/")
        let port = Int(slashSplit.head)
        let database = slashSplit.tail ?? (parts.count >= 3 ? parts[2] : "")
        return Endpoint(host: parts[0], port: port, database: database, username: nil)
    }

    private static func hostPortPath(_ descriptor: String) -> Endpoint? {
        let slashSplit = splitOnce(descriptor, separator: "/")
        let (host, port) = parseHostPort(slashSplit.head)
        guard !host.isEmpty else { return nil }
        return Endpoint(host: host, port: port, database: slashSplit.tail ?? "", username: nil)
    }

    // MARK: - File Form

    // jdbc:sqlite:/path/to/file.db, jdbc:duckdb:/path/to/file.duckdb
    private static func parseFilePath(_ body: String, subprotocol: String) -> Endpoint? {
        let path = strippingPrefix(subprotocol + ":", from: body) ?? body
        return Endpoint(host: "", port: nil, database: stripQuery(from: path), username: nil)
    }

    // MARK: - BigQuery Form

    // jdbc:bigquery://https://www.googleapis.com/bigquery/v2;ProjectId=my-project;...
    private static func parseBigQuery(_ body: String) -> Endpoint? {
        let remainder = strippingPrefix("bigquery:", from: body) ?? body
        guard remainder.hasPrefix("//") else { return nil }
        let semicolonSplit = splitOnce(String(remainder.dropFirst(2)), separator: ";")
        let properties = parseSemicolonProperties(semicolonSplit.tail ?? "")
        let project = properties["projectid"] ?? properties["project"] ?? ""
        return Endpoint(host: semicolonSplit.head, port: nil, database: project, username: nil)
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

    // The pairs after `?`, or after SQL Server's first `;`, trimmed and in their own case.
    private static func queryPairs(
        _ url: String,
        separators: Set<Character>,
        semicolonStartsQuery: Bool = true
    ) -> [(key: String, value: String)] {
        let semicolon = semicolonStartsQuery ? url.firstIndex(of: ";") : nil
        guard let start = url.firstIndex(of: "?") ?? semicolon else { return [] }
        return url[url.index(after: start)...]
            .split(whereSeparator: { separators.contains($0) })
            .compactMap { pair in
                guard let equals = pair.firstIndex(of: "=") else { return nil }
                return (
                    key: pair[..<equals].trimmingCharacters(in: .whitespaces),
                    value: pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                )
            }
    }

    private static func urlParameter(_ url: String, name: String) -> String? {
        queryPairs(url, separators: ["&", ";"]).last { $0.key.lowercased() == name.lowercased() }?.value
    }

    // A user name in a URL escapes `@`, `:` and the like as `%40`; a malformed escape stays as written.
    static func percentDecoded(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        // Escapes that decode to invalid UTF-8 leave the text as written.
        return String(bytes: decoded, encoding: .utf8) ?? text
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func strippingPrefix(_ prefix: String, from value: String) -> String? {
        guard value.prefix(prefix.count).lowercased() == prefix.lowercased() else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}
