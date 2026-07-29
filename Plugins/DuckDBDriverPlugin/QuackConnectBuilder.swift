//
//  QuackConnectBuilder.swift
//  DuckDBDriverPlugin
//

import Foundation

enum QuackConnectBuilder {
    static let defaultPort = 9_494

    static func isValidHost(_ host: String) -> Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func normalizedPort(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return defaultPort }
        guard let port = Int(trimmed), (1...65_535).contains(port) else { return nil }
        return port
    }

    static func secretSQL(token: String) -> String {
        "CREATE OR REPLACE SECRET (TYPE quack, TOKEN '\(escapeLiteral(token))')"
    }

    static func attachSQL(host: String, port: Int, alias: String) -> String {
        "ATTACH '\(quackTarget(host: host, port: port))' AS \(quoteIdentifier(alias))"
    }

    static func useSQL(alias: String) -> String {
        "USE \(quoteIdentifier(alias))"
    }

    private static func quackTarget(host: String, port: Int) -> String {
        "quack:\(escapeLiteral(host)):\(port)"
    }

    private static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "'", with: "''")
    }

    private static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
