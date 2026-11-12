//
//  SnowflakeConnectionRegistry.swift
//  SnowflakeDriverPlugin
//
//  Shares one authenticated SnowflakeConnection across the driver instances
//  the app pools for a connection profile. One TablePro connection maps to one
//  Snowflake session, so metadata drivers and switchers reuse the session
//  token instead of opening fresh logins that re-prompt for MFA.
//

import Foundation
import TableProPluginKit
import TableProSnowflakeCore

final class SnowflakeConnectionRegistry: @unchecked Sendable {
    static let shared = SnowflakeConnectionRegistry()

    private let lock = NSLock()
    private var entries: [String: (connection: SnowflakeConnection, refCount: Int)] = [:]

    // Keyed before anything is built: a connection owns two URLSessions, which a discarded copy would leak.
    func acquire(config: DriverConnectionConfig) -> SnowflakeConnection {
        let params = SnowflakeConnection.resolveParameters(from: config)
        let key = SnowflakeConnection.sessionFingerprint(
            params: params,
            account: SnowflakeAccount(params.account),
            connectionIdentifier: SnowflakeConnection.connectionIdentifier(of: config)
        )
        return lock.withLock {
            if let entry = entries[key] {
                entries[key] = (entry.connection, entry.refCount + 1)
                return entry.connection
            }
            let connection = SnowflakeConnection(config: config, params: params)
            entries[key] = (connection, 1)
            return connection
        }
    }

    func release(_ connection: SnowflakeConnection) {
        let shouldDisconnect: Bool = lock.withLock {
            let key = connection.sessionFingerprint
            guard let entry = entries[key], entry.connection === connection else { return true }
            if entry.refCount <= 1 {
                entries[key] = nil
                return true
            }
            entries[key] = (entry.connection, entry.refCount - 1)
            return false
        }
        if shouldDisconnect {
            connection.disconnect()
        }
    }
}
