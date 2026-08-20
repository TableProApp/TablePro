//
//  HiredisSentinelTransport.swift
//  RedisDriverPlugin
//
//  Talks to a Sentinel over a short-lived hiredis connection.
//
//  A Sentinel is not a data node: it accepts PING, INFO and the SENTINEL command family and
//  answers anything else with "unknown command". So this never selects a database and never
//  reuses the data-plane credentials, which belong to a different plane entirely.
//

import Foundation
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisSentinel")

struct HiredisSentinelTransport: RedisSentinelTransport {
    let username: String?
    let password: String?
    let sslConfig: SSLConfiguration
    let connectTimeout: TimeInterval

    init(
        username: String? = nil,
        password: String? = nil,
        sslConfig: SSLConfiguration = SSLConfiguration(),
        connectTimeout: TimeInterval = 4
    ) {
        self.username = username
        self.password = password
        self.sslConfig = sslConfig
        self.connectTimeout = connectTimeout
    }

    func primaryAddress(group: String, at sentinel: RedisNodeAddress) async throws -> RedisSentinelReply {
        let reply = try await run(["SENTINEL", "get-master-addr-by-name", group], at: sentinel)
        return try RedisSentinelResolver.parseAddressReply(Self.tokens(from: reply), from: sentinel)
    }

    func peerSentinels(group: String, at sentinel: RedisNodeAddress) async throws -> [RedisNodeAddress] {
        RedisSentinelResolver.parseNodeMaps(try await run(["SENTINEL", "sentinels", group], at: sentinel))
    }

    func monitoredGroups(at sentinel: RedisNodeAddress) async throws -> [String] {
        RedisSentinelResolver.parseGroupNames(try await run(["SENTINEL", "masters"], at: sentinel))
    }

    private func run(_ command: [String], at sentinel: RedisNodeAddress) async throws -> RedisReply {
        let connection = RedisPluginConnection(
            host: sentinel.host,
            port: sentinel.port,
            username: username,
            password: password,
            database: 0,
            sslConfig: sslConfig,
            connectTimeout: connectTimeout
        )
        try await connection.connect()
        defer { connection.disconnect() }

        let reply = try await connection.executeCommand(command)
        if let message = reply.errorMessage {
            logger.debug("Sentinel \(sentinel.identifier, privacy: .public) refused: \(message, privacy: .public)")
            throw RedisSentinelError.refused(sentinel, detail: message)
        }
        return reply
    }

    /// A nil bulk string means "no such group"; anything else is the array we asked for.
    static func tokens(from reply: RedisReply) -> [String?]? {
        switch reply {
        case .null:
            return nil
        case .array(let items):
            guard !items.isEmpty else { return nil }
            return items.map { item in
                if case .null = item { return nil }
                return item.stringValue
            }
        default:
            return [reply.stringValue]
        }
    }
}
