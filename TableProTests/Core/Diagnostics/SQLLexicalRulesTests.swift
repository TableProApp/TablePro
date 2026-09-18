//
//  SQLLexicalRulesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
@Suite("SQL lexical rules for an engine")
struct SQLLexicalRulesTests {
    private func rules(for databaseType: DatabaseType) -> SQLLexicalRules {
        SQLLexicalRules(databaseType: databaseType, descriptor: PluginManager.shared.sqlDialect(for: databaseType))
    }

    @Test("A backslash escapes where the dialect or the engine's descriptor says it does")
    func backslashEscapes() {
        #expect(rules(for: .mysql).backslashEscapes)
        #expect(rules(for: .clickhouse).backslashEscapes)
        #expect(rules(for: .snowflake).backslashEscapes)
        #expect(!rules(for: .postgresql).backslashEscapes)
        #expect(!rules(for: .sqlite).backslashEscapes)
    }

    @Test("Brackets quote identifiers on SQL Server and on every SQLite engine")
    func bracketedIdentifiers() {
        #expect(rules(for: .mssql).bracketsDelimitIdentifiers)
        for engine in [DatabaseType.sqlite, .libsql, .turso, .cloudflareD1] {
            #expect(rules(for: engine).bracketsDelimitIdentifiers, "\(engine.rawValue)")
        }
        for engine in [DatabaseType.duckdb, .postgresql, .mysql, .clickhouse] {
            #expect(!rules(for: engine).bracketsDelimitIdentifiers, "\(engine.rawValue)")
        }
    }

    @Test("An engine with no descriptor keeps its dialect's rules")
    func missingDescriptor() {
        #expect(SQLLexicalRules(databaseType: .mysql, descriptor: nil) == SQLLexicalRules(dialect: .mysql))
        #expect(
            SQLLexicalRules(databaseType: DatabaseType(rawValue: "FutureSQL"), descriptor: nil)
                == SQLLexicalRules(dialect: .generic)
        )
    }
}
