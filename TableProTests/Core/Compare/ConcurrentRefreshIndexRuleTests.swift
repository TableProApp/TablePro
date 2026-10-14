//
//  ConcurrentRefreshIndexRuleTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// The rule PostgreSQL applies to `REFRESH MATERIALIZED VIEW CONCURRENTLY`, as the index read
/// reports it. Each shape was measured on PostgreSQL 17.11.
struct ConcurrentRefreshIndexRuleTests {
    private func index(
        unique: Bool = true,
        type: EditableIndexDefinition.IndexType = .btree,
        columns: [String] = ["id"],
        expressions: [String] = [],
        includedColumns: [String] = [],
        whereClause: String? = nil
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: "i", columns: columns, type: type, isUnique: unique, isPrimary: false,
            comment: nil, whereClause: whereClause, expressions: expressions, includedColumns: includedColumns
        )
    }

    @Test
    func aPlainUniqueIndexAllowsIt() {
        #expect(ConcurrentRefreshIndexRule.isUsable(index()))
        #expect(ConcurrentRefreshIndexRule.isUsable(index(columns: ["customer", "id"])))
        #expect(ConcurrentRefreshIndexRule.isUsable(index(includedColumns: ["customer"])))
    }

    @Test
    func aPredicateAnExpressionOrANonUniqueIndexDoesNot() {
        #expect(!(ConcurrentRefreshIndexRule.isUsable(index(whereClause: "id > 0"))))
        #expect(!(ConcurrentRefreshIndexRule.isUsable(index(columns: ["(id + 0)"], expressions: ["(id + 0)"]))))
        #expect(!(ConcurrentRefreshIndexRule.isUsable(index(unique: false))))
        #expect(!(ConcurrentRefreshIndexRule.isUsable(index(type: .gist))))
    }

    @Test
    func oneUsableIndexIsEnough() {
        #expect(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([index(unique: false), index()]))
        #expect(!(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([index(unique: false)])))
        #expect(!ConcurrentRefreshIndexRule.allowsConcurrentRefresh([]))
    }
}
