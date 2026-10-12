//
//  MySQLFunctionalKeyParts.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum MySQLFunctionalKeyParts {
    private static let firstRelease = (8, 0, 13)

    static func catalogReportsExpressions(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        flavor == .mysql && MySQLServerVersion.isAtLeast(firstRelease, banner: banner)
    }

    static func refusal(for index: PluginIndexDefinition, banner: String?, flavor: MySQLServerFlavor) -> String? {
        guard let expressions = index.expressions, !expressions.isEmpty else { return nil }
        switch flavor {
        case .mariadb:
            return String(
                format: String(localized: "%@ cannot index an expression. Index a generated column instead."),
                "MariaDB"
            )
        case .mysql:
            guard MySQLServerVersion.isKnownBelow(firstRelease, banner: banner) else { return nil }
            return String(localized: "Indexing an expression needs MySQL 8.0.13 or later.")
        case .tidb, .oceanbase, .databend:
            return nil
        }
    }

    static func unescaped(_ catalogExpression: String) -> String {
        var result = ""
        var escaping = false
        for character in catalogExpression {
            if !escaping, character == "\\" {
                escaping = true
                continue
            }
            escaping = false
            result.append(character)
        }
        return result
    }
}
