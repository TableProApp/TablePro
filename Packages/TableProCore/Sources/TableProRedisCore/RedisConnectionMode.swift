//
//  How the connection form's fields become a topology choice.
//

import Foundation

public enum RedisConnectionMode: String, Sendable, CaseIterable {
    case standalone
    case sentinel
    case cluster

    public static let fieldId = "redisMode"

    public static func resolve(additionalFields: [String: String]) -> RedisConnectionMode {
        let raw = (additionalFields[fieldId] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // "single" was the value the first draft of the Sentinel form shipped with.
        if raw == "single" { return .standalone }
        return RedisConnectionMode(rawValue: raw) ?? .standalone
    }

    var usesHostList: Bool { self != .standalone }
}

public enum RedisSentinelFieldKey {
    public static let hosts = "redisSentinelHosts"
    public static let masterName = "redisSentinelMasterName" // swiftlint:disable:this inclusive_language
    public static let username = "redisSentinelUsername"
    public static let password = "redisSentinelPassword"
    public static let defaultPort = 26_379
    public static let defaultMasterName = "mymaster" // swiftlint:disable:this inclusive_language
}

public enum RedisClusterFieldKey {
    public static let hosts = "redisClusterHosts"
    public static let defaultPort = 6_379
}

public enum RedisHostListParser {
    /// The connection form stores a host list as a comma-separated string. An entry may omit the
    /// port, and an IPv6 literal may be bracketed.
    public static func parse(_ raw: String, defaultPort: Int) -> [RedisNodeAddress] {
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

    public static func parsePort(_ text: String) -> Int? {
        guard let port = Int(text), (1 ... 65_535).contains(port) else { return nil }
        return port
    }
}
