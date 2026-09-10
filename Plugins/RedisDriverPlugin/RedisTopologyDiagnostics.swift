//
//  RedisTopologyDiagnostics.swift
//  RedisDriverPlugin
//
//  Turns "you pointed TablePro at the wrong kind of node" into a sentence that says which field
//  to change. Issue #1021 opened on exactly this: a Sentinel port accepts the connection and then
//  refuses every data command, and a cluster node answers MOVED, so both read as bugs rather than
//  as a setting the user has not switched on yet.
//

import Foundation

enum RedisServerMode: String, Sendable {
    case standalone
    case sentinel
    case cluster
}

enum RedisServerInfo {
    static func value(_ key: String, in info: String) -> String? {
        for line in info.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func version(from info: String) -> String? { value("redis_version", in: info) }

    static func mode(from info: String) -> RedisServerMode? {
        value("redis_mode", in: info).flatMap(RedisServerMode.init(rawValue:))
    }

    /// `INFO keyspace` reports one `dbN:keys=...` line per non-empty database on this node alone.
    static func keyCount(forDatabase name: String, in info: String) -> Int? {
        guard let stats = value(name, in: info) else { return nil }
        for pair in stats.components(separatedBy: ",") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2, parts[0] == "keys", let count = Int(parts[1]) { return count }
        }
        return nil
    }
}

enum RedisTopologyDiagnostics {
    static var notAClusterMessage: String {
        String(
            localized: "This server is not running in cluster mode. Set Connection Mode to Standalone, or point Cluster mode at a node started with cluster-enabled yes."
        )
    }

    static var sentinelThroughTunnelMessage: String {
        String(
            localized: "A tunnel forwards one address, and the node Sentinel names is on the server's own network, so Sentinel mode cannot run through one. Connect to a data node directly, or turn the tunnel off."
        )
    }

    /// Called once the data connection is open, so the connection itself already succeeded and the
    /// only thing left to check is whether this is the kind of node the mode expects.
    ///
    /// `isTunneled` matters because a tunnel rewrites the connection to Standalone against the
    /// first address in the list. For Cluster that address is a data node and everything works;
    /// for Sentinel it is a Sentinel, and telling the user to pick Sentinel mode would be advice
    /// they have already followed.
    static func mismatch(
        expected: RedisConnectionMode,
        actual: RedisServerMode,
        isTunneled: Bool = false
    ) -> String? {
        if isTunneled, actual == .sentinel { return sentinelThroughTunnelMessage }
        switch (expected, actual) {
        case (.standalone, .cluster):
            return String(
                localized: "This server is part of a Redis Cluster, so requests for keys it does not own will fail. Set Connection Mode to Cluster and list this address under Cluster Seed Nodes."
            )
        case (.standalone, .sentinel), (.cluster, .sentinel):
            return String(
                localized: "This is a Redis Sentinel, not a data node, so it only answers SENTINEL commands. Set Connection Mode to Sentinel and list this address under Sentinel Nodes."
            )
        case (.sentinel, .sentinel):
            return String(
                localized: "Sentinel resolved to another Sentinel rather than a data node. Check the primary group name in your sentinel configuration."
            )
        case (.cluster, .standalone):
            return notAClusterMessage
        default:
            return nil
        }
    }
}
