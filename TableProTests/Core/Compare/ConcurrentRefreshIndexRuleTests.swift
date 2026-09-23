//
//  ConcurrentRefreshIndexRuleTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

/// The rule PostgreSQL applies to `REFRESH MATERIALIZED VIEW CONCURRENTLY`, as the index read
/// reports it. Each shape was measured on PostgreSQL 17.11.
final class ConcurrentRefreshIndexRuleTests: XCTestCase {
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

    func testAPlainUniqueIndexAllowsIt() {
        XCTAssertTrue(ConcurrentRefreshIndexRule.isUsable(index()))
        XCTAssertTrue(ConcurrentRefreshIndexRule.isUsable(index(columns: ["customer", "id"])))
        XCTAssertTrue(ConcurrentRefreshIndexRule.isUsable(index(includedColumns: ["customer"])))
    }

    func testAPredicateAnExpressionOrANonUniqueIndexDoesNot() {
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(whereClause: "id > 0")))
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(columns: ["(id + 0)"], expressions: ["(id + 0)"])))
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(unique: false)))
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(type: .gist)))
    }

    func testOneUsableIndexIsEnough() {
        XCTAssertTrue(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([index(unique: false), index()]))
        XCTAssertFalse(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([index(unique: false)]))
        XCTAssertFalse(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([]))
    }
}
