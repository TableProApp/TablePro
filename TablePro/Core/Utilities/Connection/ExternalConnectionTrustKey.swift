//
//  ExternalConnectionTrustKey.swift
//  TablePro
//

import Foundation

internal struct ExternalConnectionTrustKey: Hashable, Codable, Sendable {
    internal let databaseType: String
    internal let host: String
    internal let database: String
    internal let username: String
    internal let scopeName: String

    internal init(databaseType: String, host: String, database: String, username: String, scopeName: String) {
        self.databaseType = databaseType.lowercased()
        self.host = host.trimmingCharacters(in: .whitespaces).lowercased()
        self.database = database
        self.username = username
        self.scopeName = scopeName.trimmingCharacters(in: .whitespaces)
    }

    internal init(connection: DatabaseConnection, scopeName: String?) {
        self.init(
            databaseType: connection.type.rawValue,
            host: connection.host,
            database: connection.database,
            username: connection.username,
            scopeName: scopeName ?? ""
        )
    }

    internal var isLoopbackHost: Bool {
        LoopbackHost.isLoopback(host)
    }

    internal var displayDescription: String {
        var target = host
        if !username.isEmpty {
            target = "\(username)@\(host)"
        }
        if !database.isEmpty {
            target += "/\(database)"
        }
        guard !scopeName.isEmpty else { return "\(databaseType) \(target)" }
        return "\(databaseType) \(target) (\(scopeName))"
    }
}
