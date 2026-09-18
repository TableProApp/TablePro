//
//  QueryClassifierBeancountTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryClassifier on Beancount")
struct QueryClassifierBeancountTests {
    @Test(
        "Every statement a Beancount ledger answers is a read",
        arguments: [
            "BQL: SELECT account, sum(position) GROUP BY account",
            "bql BALANCES",
            "BQL: JOURNAL 'Assets:Checking'",
            "BQL: PRINT FROM year = 2026",
            "SELECT * FROM transactions",
            "PRAGMA table_info(transactions)",
            "pragma database_list"
        ]
    )
    func readsAreSafe(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .beancount) == .safe)
    }

    @Test("A write typed against a ledger is still a write, so Read-Only refuses it with its own message")
    func writesStayWrites() {
        #expect(QueryClassifier.classifyTier("DELETE FROM transactions", databaseType: .beancount) != .safe)
        #expect(QueryClassifier.classifyTier("PRAGMA journal_mode = WAL", databaseType: .beancount) != .safe)
    }

    @Test("The BQL prefix means nothing on another engine")
    func prefixIsBeancountOnly() {
        #expect(QueryClassifier.classifyTier("BQL: SELECT 1", databaseType: .sqlite) != .safe)
    }
}
