//
//  SQLBoundaryValidatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLBoundaryValidator")
struct SQLBoundaryValidatorTests {
    @Test("Plain filter conditions are allowed")
    func allowsPlainConditions() {
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("age > 18"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("status IN ('active','pending')"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("created_at BETWEEN '2020-01-01' AND '2021-01-01'"))
    }

    @Test("Stacked destructive statements are rejected")
    func rejectsStackedStatements() {
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; DROP TABLE users"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("x = 1 ; delete from t"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("a = 1;TRUNCATE t"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("id = 1; UPDATE t SET x = 2"))
    }

    @Test("Comment injection is rejected")
    func rejectsCommentInjection() {
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("id = 1 -- ignored"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("id = 1 /* block */"))
    }
}
