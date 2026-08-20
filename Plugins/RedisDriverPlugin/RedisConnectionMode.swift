//
//  RedisConnectionMode.swift
//  RedisDriverPlugin
//
//  How the connection form's fields become a topology choice.
//

import Foundation

enum RedisConnectionMode: String, Sendable, CaseIterable {
    case standalone
    case sentinel
    case cluster

    static let fieldId = "redisMode"

    static func resolve(additionalFields: [String: String]) -> RedisConnectionMode {
        let raw = (additionalFields[fieldId] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // "single" was the value the first draft of the Sentinel form shipped with.
        if raw == "single" { return .standalone }
        return RedisConnectionMode(rawValue: raw) ?? .standalone
    }

    var usesHostList: Bool { self != .standalone }

    /// Redis Cluster serves database 0 only, and refuses SELECT with any other index.
    var supportsDatabaseSelection: Bool { self != .cluster }
}

enum RedisSentinelFieldKey {
    static let hosts = "redisSentinelHosts"
    static let masterName = "redisSentinelMasterName"
    static let username = "redisSentinelUsername"
    static let password = "redisSentinelPassword"
    static let defaultPort = 26_379
    static let defaultMasterName = "mymaster"
}

enum RedisClusterFieldKey {
    static let hosts = "redisClusterHosts"
    static let defaultPort = 6_379
}

enum RedisHostListParser {
    /// The connection form stores a host list as a comma-separated string. An entry may omit the
    /// port, and an IPv6 literal may be bracketed.
    static func parse(_ raw: String, defaultPort: Int) -> [RedisNodeAddress] {
        raw.split(separator: ",").compactMap { entry in
            parseEntry(entry.trimmingCharacters(in: .whitespaces), defaultPort: defaultPort)
        }
    }

    static func parseEntry(_ entry: String, defaultPort: Int) -> RedisNodeAddress? {
        guard !entry.isEmpty else { return nil }

        if entry.hasPrefix("[") {
            guard let closing = entry.firstIndex(of: "]") else { return nil }
            let host = String(entry[entry.index(after: entry.startIndex) ..< closing])
            guard !host.isEmpty else { return nil }
            let afterBracket = entry.index(after: closing)
            guard afterBracket != entry.endIndex else {
                return RedisNodeAddress(host: host, port: defaultPort)
            }
            guard entry[afterBracket] == ":",
                  let port = parsePort(String(entry[entry.index(after: afterBracket)...])) else { return nil }
            return RedisNodeAddress(host: host, port: port)
        }

        // A bare IPv6 literal has several colons and no port, so only a single colon splits.
        if let lastColon = entry.lastIndex(of: ":"), !entry[..<lastColon].contains(":") {
            let host = String(entry[..<lastColon])
            guard !host.isEmpty, let port = parsePort(String(entry[entry.index(after: lastColon)...])) else {
                return nil
            }
            return RedisNodeAddress(host: host, port: port)
        }

        return RedisNodeAddress(host: entry, port: defaultPort)
    }

    static func parsePort(_ text: String) -> Int? {
        guard let port = Int(text), (1 ... 65_535).contains(port) else { return nil }
        return port
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
