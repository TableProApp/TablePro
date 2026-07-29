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

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

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
        var normalized = host
        while normalized.hasSuffix(".") { normalized.removeLast() }
        if Self.loopbackHosts.contains(normalized) { return true }
        return Self.isLoopbackIPv4(normalized)
    }

    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard !octet.isEmpty,
                  octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(octet), value <= 255
            else { return false }
        }
        return Int(octets[0]) == 127
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
