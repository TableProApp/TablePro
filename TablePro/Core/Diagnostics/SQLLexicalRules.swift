//
//  SQLLexicalRules.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct SQLLexicalRules: Equatable, Sendable {
    private static let enginesAcceptingBracketedIdentifiers: Set<DatabaseType> = [
        .sqlite, .libsql, .turso, .cloudflareD1
    ]

    let dialect: SqlDialect
    let backslashEscapes: Bool
    let bracketsDelimitIdentifiers: Bool

    init(dialect: SqlDialect, backslashEscapes: Bool, bracketsDelimitIdentifiers: Bool) {
        self.dialect = dialect
        self.backslashEscapes = backslashEscapes
        self.bracketsDelimitIdentifiers = bracketsDelimitIdentifiers
    }

    init(dialect: SqlDialect) {
        self.init(
            dialect: dialect,
            backslashEscapes: dialect.requiresBackslashEscapesInSingleQuotes,
            bracketsDelimitIdentifiers: false
        )
    }

    init(databaseType: DatabaseType, descriptor: SQLDialectDescriptor?) {
        let dialect = SqlDialect.from(databaseTypeId: databaseType.rawValue)
        self.init(
            dialect: dialect,
            backslashEscapes: dialect.requiresBackslashEscapesInSingleQuotes
                || descriptor?.requiresBackslashEscaping == true,
            bracketsDelimitIdentifiers: descriptor?.identifierQuote == "["
                || Self.enginesAcceptingBracketedIdentifiers.contains(databaseType)
        )
    }
}
