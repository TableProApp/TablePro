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
import os
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisSentinel")

struct HiredisSentinelTransport: RedisSentinelTransport {
    let username: String?
    let password: String?
    let sslConfig: SSLConfiguration

    init(
        username: String? = nil,
        password: String? = nil,
        sslConfig: SSLConfiguration = SSLConfiguration()
    ) {
        self.username = username
        self.password = password
        self.sslConfig = sslConfig
    }

    func primaryAddress(
        group: String,
        at sentinel: RedisNodeAddress,
        deadline: RedisConnectDeadline
    ) async throws -> RedisSentinelReply {
        let reply = try await run(["SENTINEL", "get-master-addr-by-name", group], at: sentinel, deadline: deadline)
        return try RedisSentinelResolver.parseAddressReply(Self.tokens(from: reply), from: sentinel)
    }

    func peerSentinels(
        group: String,
        at sentinel: RedisNodeAddress,
        deadline: RedisConnectDeadline
    ) async throws -> [RedisNodeAddress] {
        RedisSentinelResolver.parseNodeMaps(
            try await run(["SENTINEL", "sentinels", group], at: sentinel, deadline: deadline)
        )
    }

    func monitoredGroups(at sentinel: RedisNodeAddress, deadline: RedisConnectDeadline) async throws -> [String] {
        RedisSentinelResolver.parseGroupNames(
            try await run(["SENTINEL", "masters"], at: sentinel, deadline: deadline)
        )
    }

    private func run(
        _ command: [String],
        at sentinel: RedisNodeAddress,
        deadline: RedisConnectDeadline
    ) async throws -> RedisReply {
        guard let remainingMilliseconds = deadline.remainingMilliseconds() else {
            throw RedisSentinelError.deadlineExceeded(tried: [sentinel])
        }
        let connection = RedisPluginConnection(
            host: sentinel.host,
            port: sentinel.port,
            username: username,
            password: password,
            database: 0,
            sslConfig: sslConfig,
            connectTimeoutMilliseconds: remainingMilliseconds
        )
        do {
            try await connection.connect()
        } catch let error as RedisPluginError where error.refusedByServer {
            logger.debug("Sentinel \(sentinel.identifier, privacy: .public) refused: \(RedisConnectProbe.errorClass(of: error.message), privacy: .public) \(error.message, privacy: .private)")
            throw RedisSentinelError.refused(sentinel, detail: error.message)
        }
        defer { connection.disconnect() }

        let reply = try await connection.executeCommand(command)
        if let message = reply.errorMessage {
            logger.debug("Sentinel \(sentinel.identifier, privacy: .public) refused: \(RedisConnectProbe.errorClass(of: message), privacy: .public) \(message, privacy: .private)")
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
