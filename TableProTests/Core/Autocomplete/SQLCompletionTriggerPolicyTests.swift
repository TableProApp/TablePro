//
//  SQLCompletionTriggerPolicyTests.swift
//  TableProTests
//
//  The rule the query editor and the raw SQL filter share for whether a keystroke opens the list.
//  Both surfaces reach it through an engine and a schema provider, so the rule itself had no test
//  that did not also pay for candidate generation.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQL Completion Trigger Policy")
struct SQLCompletionTriggerPolicyTests {
    private static func context(
        clause: SQLClauseType,
        prefix: String = "",
        prefixRange: Range<Int> = 0..<0,
        dotPrefix: String? = nil,
        isAfterComma: Bool = false
    ) -> SQLContext {
        SQLContext(
            clauseType: clause,
            prefix: prefix,
            prefixRange: prefixRange,
            dotPrefix: dotPrefix,
            tableReferences: [],
            isInsideString: false,
            isInsideComment: false,
            isAfterComma: isAfterComma
        )
    }

    private static func suppresses(_ context: SQLContext, _ trigger: SQLCompletionTrigger = .automatic) -> Bool {
        SQLCompletionTriggerPolicy.suppressesEmptyPrefix(context, trigger: trigger)
    }

    @Test(
        "A clause whose answer is a short closed list opens with nothing typed",
        arguments: [
            SQLClauseType.from, .join, .into, .set, .insertColumns, .on,
            .alterTableColumn, .returning, .using, .dropObject, .createIndex, .castTarget
        ]
    )
    func closedListClausesOpen(clause: SQLClauseType) {
        #expect(!Self.suppresses(Self.context(clause: clause)))
    }

    @Test(
        "A clause with the whole column list behind it stays shut",
        arguments: [SQLClauseType.where_, .and, .having, .groupBy, .orderBy, .values, .unknown]
    )
    func noisyClausesStayShut(clause: SQLClauseType) {
        #expect(Self.suppresses(Self.context(clause: clause)))
    }

    @Test("The first item after SELECT opens, a later one does not")
    func selectOpensOnlyOnItsFirstItem() {
        #expect(!Self.suppresses(Self.context(clause: .select)))
        #expect(Self.suppresses(Self.context(clause: .select, isAfterComma: true)))
    }

    /// An opening identifier quote matches nothing, so the analyzer strips it from the prefix and
    /// keeps it in the range. Reading the prefix alone reads that as an untouched position.
    @Test("A typed opening quote is input, even though it matches nothing")
    func aTypedQuoteCountsAsInput() {
        #expect(!Self.suppresses(Self.context(clause: .where_, prefixRange: 0..<1)))
    }

    @Test("A qualified name opens whatever clause it sits in")
    func aDotPrefixIsAlwaysExempt() {
        #expect(!Self.suppresses(Self.context(clause: .where_, dotPrefix: "users")))
    }

    @Test("A typed prefix is never suppressed")
    func aTypedPrefixIsNeverSuppressed() {
        #expect(!Self.suppresses(Self.context(clause: .where_, prefix: "na", prefixRange: 0..<2)))
    }

    @Test(
        "Asking for the list explicitly answers at every position",
        arguments: [SQLClauseType.where_, .and, .having, .groupBy, .orderBy, .unknown]
    )
    func anExplicitRequestIsNeverSuppressed(clause: SQLClauseType) {
        #expect(!Self.suppresses(Self.context(clause: clause), .explicit))
        #expect(!Self.suppresses(Self.context(clause: clause, isAfterComma: true), .explicit))
    }
}
