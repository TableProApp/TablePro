//
//  DatabaseTreeRenameTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// The three answers `RenameNameDecision` gives are separate because two of them are not failures.
@Suite("Object tree rename")
struct DatabaseTreeRenameTests {
    @Test("A new name commits")
    func newNameCommits() {
        #expect(RenameNameDecision.decide(typed: "invoices", original: "orders") == .commit("invoices"))
    }

    /// Finishing where you started is not a rename, and sending it would spend a round trip to
    /// have the server rename an object to what it is already called.
    @Test("The same name is not a rename")
    func unchangedNameDoesNothing() {
        #expect(RenameNameDecision.decide(typed: "orders", original: "orders") == .unchanged)
    }

    @Test("Whitespace around a name is not part of it")
    func surroundingWhitespaceIsTrimmed() {
        #expect(RenameNameDecision.decide(typed: "  invoices  ", original: "orders") == .commit("invoices"))
        #expect(RenameNameDecision.decide(typed: "  orders  ", original: "orders") == .unchanged)
    }

    /// Clearing the field is how a rename is abandoned, so it is discarded rather than sent for
    /// the server to answer with a syntax error.
    @Test("An empty name is discarded")
    func emptyNameIsDiscarded() {
        #expect(RenameNameDecision.decide(typed: "", original: "orders") == .discard)
        #expect(RenameNameDecision.decide(typed: "   ", original: "orders") == .discard)
    }

    /// A name that differs only in case is a real rename on every engine that folds case, because
    /// the stored spelling is what the user sees.
    @Test("A name differing only in case is a rename")
    func caseOnlyChangeIsARename() {
        #expect(RenameNameDecision.decide(typed: "Orders", original: "orders") == .commit("Orders"))
    }
}
