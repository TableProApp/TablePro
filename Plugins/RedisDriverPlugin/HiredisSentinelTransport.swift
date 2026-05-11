//
//  HiredisSentinelTransport.swift
//  RedisDriverPlugin
//
//  Production SentinelTransport backed by short-lived hiredis connections.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "HiredisSentinelTransport")

struct HiredisSentinelTransport: SentinelTransport {
    let sslConfig: RedisSSLConfig

    init(sslConfig: RedisSSLConfig = RedisSSLConfig()) {
        self.sslConfig = sslConfig
    }

    func queryMasterAddress(
        masterName: String,
        at sentinel: SentinelHostPort,
        sentinelUsername: String?,
        sentinelPassword: String?
    ) async throws -> SentinelMasterReply {
        let connection = RedisPluginConnection(
            host: sentinel.host,
            port: sentinel.port,
            username: sentinelUsername?.nonEmptyOrNil,
            password: sentinelPassword?.nonEmptyOrNil,
            database: 0,
            sslConfig: sslConfig
        )

        try await connection.connect()
        defer { connection.disconnect() }

        let reply = try await connection.executeCommand([
            "SENTINEL", "get-master-addr-by-name", masterName,
        ])

        if case .error(let message) = reply {
            logger.debug("Sentinel \(sentinel.host):\(sentinel.port) replied with error: \(message)")
            throw RedisPluginError(code: 0, message: message)
        }

        let tokens = Self.extractTokens(from: reply)
        return try RedisSentinelResolver.parseMasterReplyTokens(tokens, from: sentinel)
    }

    static func extractTokens(from reply: RedisReply) -> [String?]? {
        switch reply {
        case .null:
            return nil
        case .array(let items):
            if items.isEmpty { return nil }
            return items.map { item -> String? in
                if case .null = item { return nil }
                return item.stringValue
            }
        default:
            return [reply.stringValue]
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
