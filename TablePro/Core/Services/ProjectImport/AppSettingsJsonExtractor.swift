//
//  AppSettingsJsonExtractor.swift
//  TablePro
//

import Foundation

enum AppSettingsJsonExtractor {
    static func extract(data: Data, relativePath: String) -> [ScannedConnectionCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let strings = connectionStrings(in: root) else {
            return []
        }
        return strings.sorted { $0.key < $1.key }.compactMap { name, value in
            candidate(name: name, connectionString: value, relativePath: relativePath)
        }
    }

    private static func connectionStrings(in root: [String: Any]) -> [String: String]? {
        for (key, value) in root where key.lowercased() == "connectionstrings" {
            guard let nested = value as? [String: Any] else {
                continue
            }
            return nested.compactMapValues { $0 as? String }
        }
        return nil
    }

    static func candidate(
        name: String,
        connectionString: String,
        relativePath: String
    ) -> ScannedConnectionCandidate? {
        let keywords = parseKeywords(connectionString)
        guard let type = provider(for: keywords) else {
            return nil
        }
        var fields = ScannedConnectionFields(type: type)
        fields.host = first(keywords, ["host", "server", "data source", "address", "addr", "network address"]) ?? ""
        fields.database = first(keywords, ["database", "initial catalog"]) ?? ""
        fields.username = first(keywords, ["username", "user id", "uid", "user"]) ?? ""
        fields.password = first(keywords, ["password", "pwd"]) ?? ""
        fields.connectionName = name
        let address = splitHostPort(fields.host, type: type)
        fields.host = address.host
        fields.port = first(keywords, ["port"]).flatMap { Int($0) } ?? address.port ?? type.defaultPort
        return ScannedConnectionCandidate(
            parsedURL: fields.toParsedConnectionURL(),
            sourceRelativePath: relativePath,
            sourceKey: "ConnectionStrings:\(name)",
            kind: .appSettingsJson,
            tier: .configFile
        )
    }

    static func parseKeywords(_ connectionString: String) -> [String: String] {
        var keywords: [String: String] = [:]
        for segment in connectionString.split(separator: ";") {
            guard let equals = segment.firstIndex(of: "=") else {
                continue
            }
            let key = String(segment[segment.startIndex..<equals])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(segment[segment.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else {
                continue
            }
            keywords[key] = value
        }
        return keywords
    }

    static func provider(for keywords: [String: String]) -> DatabaseType? {
        if keywords["host"] != nil {
            return .postgresql
        }
        if keywords["initial catalog"] != nil {
            return .mssql
        }
        let sqlServerHints = ["trusted_connection", "encrypt", "trustservercertificate", "integrated security"]
        if sqlServerHints.contains(where: { keywords[$0] != nil }) {
            return .mssql
        }
        if keywords["uid"] != nil || keywords["pwd"] != nil {
            return .mysql
        }
        return nil
    }

    private static func first(_ keywords: [String: String], _ names: [String]) -> String? {
        for name in names {
            if let value = keywords[name] {
                return value
            }
        }
        return nil
    }

    private static func splitHostPort(_ value: String, type: DatabaseType) -> (host: String, port: Int?) {
        let separator: Character = type == .mssql ? "," : ":"
        guard let index = value.firstIndex(of: separator) else {
            return (value, nil)
        }
        let head = String(value[value.startIndex..<index])
        let tail = String(value[value.index(after: index)...])
        guard let port = Int(tail) else {
            return (value, nil)
        }
        return (head, port)
    }
}
