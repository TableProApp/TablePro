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

final class SnowflakeConnectionRegistry: @unchecked Sendable {
    static let shared = SnowflakeConnectionRegistry()

    private let lock = NSLock()
    private var entries: [String: (connection: SnowflakeConnection, refCount: Int)] = [:]

    func acquire(config: DriverConnectionConfig) -> SnowflakeConnection {
        lock.withLock {
            let candidate = SnowflakeConnection(config: config)
            let key = candidate.sessionFingerprint
            if let entry = entries[key] {
                entries[key] = (entry.connection, entry.refCount + 1)
                return entry.connection
            }
            entries[key] = (candidate, 1)
            return candidate
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
