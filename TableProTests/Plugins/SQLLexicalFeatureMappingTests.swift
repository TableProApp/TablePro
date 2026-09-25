//
//  SQLLexicalFeatureMappingTests.swift
//  TableProTests
//
//  The kit carries its own copy of the lexical rules, because a plugin cannot link the app's package. These hold the
//  two copies to one another: the feature bits, the grammars two plugins keep for themselves, and where each copy
//  splits the same text.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct SQLLexicalFeatureMappingTests {
    @Test("Every grammar fact has exactly one kit feature, on the same bit")
    func everyFactHasAPartner() {
        let pairs = SQLLexicalGrammar.pluginFeaturePairs
        let grammarBits = pairs.reduce(into: SQLLexicalGrammar()) { $0.formUnion($1.1) }
        let featureBits = pairs.reduce(into: SQLLexicalFeatures()) { $0.formUnion($1.0) }
        #expect(pairs.allSatisfy { $0.0.rawValue == $0.1.rawValue })
        #expect(grammarBits.rawValue == featureBits.rawValue)
        #expect(Set(pairs.map(\.1.rawValue)).count == pairs.count)
        #expect(grammarBits.rawValue == (1 << 25) - 1)
    }

    @Test("A grammar survives the trip through the kit's features")
    func roundTrip() {
        let grammar = DatabaseType.postgresql.lexicalGrammar
        #expect(SQLLexicalGrammar(pluginFeatures: grammar.pluginFeatures) == grammar)
    }

    @Test("The grammars the MySQL and DuckDB plugins keep are the curated ones")
    func pluginGrammarsMatchTheCuratedTable() {
        #expect(SQLLexicalGrammar(pluginFeatures: MySQLLexicalFeatures.mySQL) == DatabaseType.mysql.lexicalGrammar)
        #expect(
            SQLLexicalGrammar(pluginFeatures: MySQLLexicalFeatures.databend) == DatabaseType.databend.lexicalGrammar
        )
        #expect(SQLLexicalGrammar(pluginFeatures: DuckDBLexicalFeatures.features) == DatabaseType.duckdb.lexicalGrammar)
    }

    @Test("NO_BACKSLASH_ESCAPES from the server status turns the backslash off in both string quotes")
    func mySQLSessionState() {
        let off = MySQLLexicalFeatures.features(for: .mysql, noBackslashEscapes: true)
        #expect(!off.contains(.backslashEscapesInSingleQuotes))
        #expect(!off.contains(.backslashEscapesInDoubleQuotes))
        #expect(MySQLLexicalFeatures.features(for: .mysql, noBackslashEscapes: false) == MySQLLexicalFeatures.mySQL)
        #expect(MySQLLexicalFeatures.sessionState(noBackslashEscapes: nil) == nil)
        #expect(MySQLLexicalFeatures.features(for: .databend, noBackslashEscapes: true) == MySQLLexicalFeatures.databend)
    }

    static let corpus = [
        "SELECT 'C:\\' AS p; DROP TABLE t",
        "SELECT 1 /* /* */ ' */; DROP TABLE t; --'",
        "SELECT [it's] FROM t; DROP TABLE t; SELECT 'x'",
        "SELECT $$it's$$; DROP TABLE t; SELECT 'x'",
        "SELECT $ü$it's$ü$; DROP TABLE t; SELECT 'x'",
        "SELECT E'\\''; DROP TABLE t; --'",
        "SELECT 1 # '\n; DROP TABLE t; -- '",
        "SELECT 'a\\'; DROP TABLE t; -- '",
        "SELECT 1 AS [a]]'b]; DROP TABLE t; SELECT 'x'",
        "SELECT q'[it's]' FROM dual; DROP TABLE t; --'",
        "SELECT 1 FROM DUAL // '\n; DELETE FROM t; -- '",
        "SELECT 1 -- x\r; DROP TABLE t",
        "SELECT 1 --x; DROP TABLE t",
        "SELECT $a('); DROP TABLE t; --'",
        "SELECT '''it's'''; DROP TABLE t; SELECT 'x'",
        "SELECT 1 /*! , '*/' */; SELECT 2",
    ]

    static let engines: [DatabaseType] = [
        .postgresql, .mysql, .sqlite, .duckdb, .oracle, .dameng, .mssql, .snowflake, .bigQuery, .cassandra,
    ]

    @Test("The kit's splitter and the app's scanner split every corpus text alike", arguments: engines)
    func kitSplitterAgreesWithTheScanner(engine: DatabaseType) {
        let grammar = engine.lexicalGrammar.subtracting([.plsqlBlocks, .slashLineTerminators, .batchSeparatorLines])
        for sql in Self.corpus {
            let scanned = SQLStatementScanner.executableStatements(in: sql, grammar: grammar).count
            let split = SQLStatementSplitting.statements(in: sql, lexicalFeatures: grammar.pluginFeatures).count
            #expect(scanned == split, "\(engine.rawValue): \(sql)")
        }
    }
}
