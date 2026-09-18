//
//  RedisClusterRedirect.swift
//  RedisDriverPlugin
//
//  Parses the cluster control errors Redis answers with instead of a result.
//  Endpoint forms verified on Redis 8.10.1: "127.0.0.1:7103", ":7103" and "?:7103" all occur,
//  and an IPv6 literal arrives unbracketed.
//

import Foundation

struct RedisNodeAddress: Equatable, Hashable, Sendable {
    let host: String
    let port: Int

    var identifier: String { "\(host):\(port)" }
}

enum RedisClusterRedirect: Equatable, Sendable {
    case moved(slot: Int, address: RedisNodeAddress)
    case ask(slot: Int, address: RedisNodeAddress)
    case tryAgain(slot: Int?)
    case clusterDown(String)
    case crossSlot

    var address: RedisNodeAddress? {
        switch self {
        case .moved(_, let address), .ask(_, let address): return address
        case .tryAgain, .clusterDown, .crossSlot: return nil
        }
    }

    var slot: Int? {
        switch self {
        case .moved(let slot, _), .ask(let slot, _): return slot
        case .tryAgain(let slot): return slot
        case .clusterDown, .crossSlot: return nil
        }
    }

    /// `fallbackHost` stands in when the server reports an empty or unknown endpoint, which it does
    /// when it has no announced address for the owning node. The spec says to reuse the endpoint of
    /// the node that answered.
    static func parse(_ message: String, fallbackHost: String) -> RedisClusterRedirect? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let code = fields.first?.uppercased() else { return nil }

        switch code {
        case "MOVED", "ASK":
            guard fields.count >= 3, let slot = Int(fields[1]),
                  let address = parseEndpoint(fields[2], fallbackHost: fallbackHost) else { return nil }
            return code == "MOVED" ? .moved(slot: slot, address: address) : .ask(slot: slot, address: address)
        case "TRYAGAIN":
            return .tryAgain(slot: fields.count >= 2 ? Int(fields[1]) : nil)
        case "CLUSTERDOWN":
            return .clusterDown(fields.dropFirst().joined(separator: " "))
        case "CROSSSLOT":
            return .crossSlot
        default:
            return nil
        }
    }

    static func parseEndpoint(_ endpoint: String, fallbackHost: String) -> RedisNodeAddress? {
        guard let lastColon = endpoint.lastIndex(of: ":") else { return nil }
        guard let port = Int(endpoint[endpoint.index(after: lastColon)...]), (1 ... 65_535).contains(port) else {
            return nil
        }
        var host = String(endpoint[..<lastColon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.isEmpty || host == "?" {
            host = fallbackHost
        }
        return RedisNodeAddress(host: host, port: port)
    }
}
