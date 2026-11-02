//
//  SQLBoundaryValidatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

// The Compare row filter runs wrapped in parentheses ahead of an ORDER BY and a row limit, so it refuses what this
// validator lets through.
struct CompareRowFilterLexingTests {
    private let commentMessage = String(localized: "A filter cannot contain a comment.")
    private let semicolonMessage = String(
        localized: "A filter is a single condition and cannot contain a semicolon."
    )
    private let unbalancedMessage = String(
        localized: "A quote or parenthesis in this filter is not closed."
    )

    // `--` then U+0301 is two Characters, `-` and `-́`, so a Character search found no `--`.
    @Test("A line comment a combining mark follows is refused")
    func commentWithCombiningMarkIsRefused() {
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("id = 1--\u{301}x"))
        #expect(CompareRowFilter.validationError(for: "id = 1--\u{301}x") == commentMessage)
        #expect(CompareRowFilter.validationError(for: "id = 1 #\u{301}x") == commentMessage)
    }

    @Test("A semicolon a combining mark follows is refused")
    func semicolonWithCombiningMarkIsRefused() {
        #expect(CompareRowFilter.validationError(for: "1=1;\u{301} DELETE FROM t") == semicolonMessage)
    }

    @Test("A quote a combining mark follows still opens and closes a literal")
    func quoteWithCombiningMarkIsLexed() {
        #expect(CompareRowFilter.validationError(for: "a = '\u{301}x'") == nil)
        #expect(CompareRowFilter.validationError(for: "a = 'x'\u{301} OR (1 = 1") == unbalancedMessage)
    }

    // PostgreSQL reads `$$ ( $$` as a literal, so the `)` after it closes the wrapper there.
    @Test("A filter balanced only outside an engine's reading is refused for that engine")
    func engineReadingIsApplied() {
        let filter = "a = $$ ( $$ ) OR (1 = 1) OR b IN ( $$ ) $$"
        #expect(CompareRowFilter.validationError(for: filter) == nil)
        #expect(CompareRowFilter.validationError(for: filter, databaseTypes: [.postgresql]) == unbalancedMessage)
        #expect(CompareRowFilter.validationError(for: "status = 'active'", databaseTypes: [.mssql, .postgresql]) == nil)
    }

    @Test("A compare scope checks each filter with the engine that runs it")
    func scopeReadsTheFilterAsItsEngine() {
        let scope = DataTableScope(sourceFilter: "a = $$ ( $$ ) OR (1 = 1) OR b IN ( $$ ) $$")
        #expect(scope.filterValidationError(source: .postgresql, target: .mysql) == unbalancedMessage)
    }
}
