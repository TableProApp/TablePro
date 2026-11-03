//
//  QuackConnectBuilder.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProSQLQuoting

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
        "CREATE OR REPLACE SECRET (TYPE quack, TOKEN \(SQLQuoting.stringLiteral(token)))"
    }

    static func attachSQL(host: String, port: Int, alias: String) -> String {
        "ATTACH \(SQLQuoting.stringLiteral("quack:\(host):\(port)")) AS \(SQLQuoting.identifier(alias))"
    }

    static func useSQL(alias: String) -> String {
        "USE \(SQLQuoting.identifier(alias))"
    }
}
