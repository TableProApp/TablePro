//
//  SnowflakeSessionKey.swift
//  SnowflakeDriverPlugin
//
//  Decides which drivers share one authenticated Snowflake session.
//

import Foundation

enum SnowflakeSessionKey {
    /// Two saved connections can reach the same account, user and role and still be different
    /// connections. Keying on the account alone let them share a session, so `USE DATABASE` in one
    /// window moved the other window's current database.
    ///
    /// The saved connection's own identifier separates them. The database cannot: the metadata pool
    /// rewrites it on its copy of the connection before building a driver, so including it here
    /// would give that driver a different key, a second login, and another MFA prompt, which is the
    /// whole reason the session is shared in the first place.
    static func fingerprint(
        connectionId: String,
        host: String,
        user: String,
        authMethod: String,
        role: String
    ) -> String {
        [connectionId, host, user.uppercased(), authMethod, role.uppercased()].joined(separator: "|")
    }
}
