//
//  SQLLexicalFeatureMappingTests.swift
//  TableProTests
//
//  The kit carries its own copy of the lexical rules, because a plugin cannot link the app's package. These hold the
//  two copies to one another: the feature bits, the grammars the MySQL plugin keeps for itself, and where each copy
//  splits the same text.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct SQLLexicalFeatureMappingTests {
    @Test("Every grammar fact but the app-curated ones has exactly one kit feature, on the same bit")
    func everyFactHasAPartner() {
        let pairs = SQLLexicalGrammar.pluginFeaturePairs
        let grammarBits = pairs.reduce(into: SQLLexicalGrammar()) { $0.formUnion($1.1) }
        let featureBits = pairs.reduce(into: SQLLexicalFeatures()) { $0.formUnion($1.0) }
        #expect(pairs.allSatisfy { $0.0.rawValue == $0.1.rawValue })
        #expect(grammarBits.rawValue == featureBits.rawValue)
        #expect(Set(pairs.map(\.1.rawValue)).count == pairs.count)
        #expect(grammarBits.rawValue == (1 << 25) - 1)
        #expect(grammarBits.isDisjoint(with: .sqlScriptBlocks))
        #expect(grammarBits.isDisjoint(with: .cqlBatches))
        let curatedOnly: SQLLexicalGrammar = [
            .sqlScriptBlocks, .cqlBatches, .hashAndAtInIdentifiers, .angleQuotedIdentifiers,
            .backslashEscapesInAngleQuotes, .escapeBytesPrefix, .exponentSignsNeedNoDigits, .formFeedEndsLineComments,
            .atomicRoutineBodies, .triggerBodies, .statementsAsValues, .bracketedStatementSources, .pipeOperatorChains,
        ]
        #expect(grammarBits.isDisjoint(with: curatedOnly))
        #expect(grammarBits.union(curatedOnly).rawValue == (1 << 38) - 1)
    }

    @Test("SAP HANA's SQLScript blocks stay in the app's curated grammar and never reach the kit")
    func sqlScriptBlocksAreAppCurated() {
        let hana = DatabaseType.sapHana.lexicalGrammar
        #expect(hana.contains(.sqlScriptBlocks))
        #expect(hana.pluginFeatures == [.dollarAndHashInIdentifiers])
        #expect(SQLLexicalGrammar(pluginFeatures: hana.pluginFeatures) == hana.subtracting(.sqlScriptBlocks))
    }

    @Test("A CQL batch stays in the app's curated grammar and never reaches the kit")
    func cqlBatchesAreAppCurated() {
        let cql = DatabaseType.cassandra.lexicalGrammar
        #expect(cql.contains(.cqlBatches))
        #expect(cql.pluginFeatures == [.untaggedDollarQuotes, .doubleSlashLineComments])
        #expect(SQLLexicalGrammar(pluginFeatures: cql.pluginFeatures) == cql.subtracting(.cqlBatches))
    }

    @Test("T-SQL name characters stay in the app's curated grammar and never reach the kit")
    func tsqlNameCharactersAreAppCurated() {
        let tsql = DatabaseType.mssql.lexicalGrammar
        #expect(tsql.contains(.hashAndAtInIdentifiers))
        #expect(SQLLexicalGrammar(pluginFeatures: tsql.pluginFeatures) == tsql.subtracting(.hashAndAtInIdentifiers))
    }

    @Test("SurrealQL's angle quotes stay in the app's curated grammar and never reach the kit")
    func angleQuotesAreAppCurated() {
        let surrealQL = DatabaseType.surrealdb.lexicalGrammar
        let curatedOnly: SQLLexicalGrammar = [.angleQuotedIdentifiers, .backslashEscapesInAngleQuotes]
        #expect(surrealQL.isSuperset(of: curatedOnly))
        #expect(
            SQLLexicalGrammar(pluginFeatures: surrealQL.pluginFeatures)
                == surrealQL.subtracting(curatedOnly.union(.statementsAsValues))
        )
    }

    @Test("CockroachDB's byte literal stays in the app's curated grammar and never reaches the kit")
    func escapeBytesPrefixIsAppCurated() {
        let cockroach = DatabaseType.cockroachdb.lexicalGrammar
        #expect(cockroach.contains(.escapeBytesPrefix))
        #expect(cockroach.pluginFeatures == DatabaseType.postgresql.lexicalGrammar.pluginFeatures)
        #expect(
            SQLLexicalGrammar(pluginFeatures: cockroach.pluginFeatures)
                == cockroach.subtracting([.escapeBytesPrefix, .atomicRoutineBodies, .bracketedStatementSources])
        )
    }

    @Test("Databend's form feed rule stays in the app's curated grammar and never reaches the kit")
    func formFeedRuleIsAppCurated() {
        let databend = DatabaseType.databend.lexicalGrammar
        #expect(databend.contains(.formFeedEndsLineComments))
        #expect(SQLLexicalGrammar(pluginFeatures: databend.pluginFeatures) == databend.subtracting(.formFeedEndsLineComments))
    }

    @Test("A grammar survives the trip through the kit's features, less the facts only the curated table sets")
    func roundTrip() {
        let grammar = DatabaseType.postgresql.lexicalGrammar
        #expect(grammar.contains(.atomicRoutineBodies))
        #expect(SQLLexicalGrammar(pluginFeatures: grammar.pluginFeatures) == grammar.subtracting(.atomicRoutineBodies))
        #expect(SQLLexicalGrammar(pluginFeatures: DatabaseType.mysql.lexicalGrammar.pluginFeatures) == DatabaseType.mysql.lexicalGrammar)
    }

    /// MySQLDriverTests' MySQLLexicalFeatureListTests pins MySQLLexicalFeatures to these same sets.
    @Test("The grammars the MySQL plugin keeps are the curated ones")
    func pluginGrammarsMatchTheCuratedTable() {
        let mySQL: SQLLexicalFeatures = [
            .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .hashLineComments,
            .executableComments, .dashCommentsNeedWhitespace, .delimiterDirective,
        ]
        let databend: SQLLexicalFeatures = [
            .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .untaggedDollarQuotes,
        ]
        #expect(SQLLexicalGrammar(pluginFeatures: mySQL) == DatabaseType.mysql.lexicalGrammar)
        let curatedDatabend = DatabaseType.databend.lexicalGrammar.subtracting(.formFeedEndsLineComments)
        #expect(SQLLexicalGrammar(pluginFeatures: databend) == curatedDatabend)
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
        "SELECT 1 --\u{7F}'\n; DROP TABLE t; -- '",
        "SELECT $a('); DROP TABLE t; --'",
        "SELECT $a(\u{01}'); DROP TABLE t; --'",
        "SELECT x$y(\"')\"); DROP TABLE t; --\"",
        "SELECT '''it's'''; DROP TABLE t; SELECT 'x'",
        "SELECT 1 /*! , '*/' */; SELECT 2",
        "/*! /* ' */ SELECT 1 */; SELECT 2",
        "/*! SELECT 1 # '\n */; SELECT 2",
        "/*! SELECT 1 -- '\n */; SELECT 2",
        "/*! SELECT /*! 1 */; SELECT 2",
        "/*m! ' */ SELECT 1; SELECT 2 -- '",
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
