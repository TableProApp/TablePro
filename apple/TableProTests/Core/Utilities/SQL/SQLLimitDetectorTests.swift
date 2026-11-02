//
//  SQLLimitDetectorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import Testing

@testable import TablePro

// The walk itself is tested in TableProSQLGrammarTests (SQLStatementRowLimitTests); this pins the dialect mapping.
struct SQLLimitDetectorTests {
    @Test("TOP counts as a row limit only under the top style")
    func topCountsOnlyUnderTopStyle() {
        let sql = "SELECT TOP 5 * FROM t"
        #expect(SQLLimitDetector.hasExplicitRowLimit(sql, autoLimitStyle: .top, grammar: TestGrammar.sqlServer))
        for style in [AutoLimitStyle.limit, .fetchFirst, .none] {
            #expect(!SQLLimitDetector.hasExplicitRowLimit(sql, autoLimitStyle: style, grammar: TestGrammar.sqlServer))
        }
    }
}
