//
//  ExactCountOutcomeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ExactCountOutcomeTests {
    private struct Throttled: LocalizedError {
        var errorDescription: String? { "Rate exceeded" }
    }

    private func makeTab() -> QueryTab {
        QueryTab(title: "orders", query: "", tabType: .table, tableName: "orders")
    }

    @Test("A failed count shows its error, and a later count that succeeds takes it down")
    func successClearsTheCountsOwnError() {
        var tab = makeTab()

        PaginationCoordinator.applyExactCount(.failure(Throttled()), to: &tab)
        #expect(tab.execution.errorMessage?.contains("Rate exceeded") == true)

        PaginationCoordinator.applyExactCount(.success(42), to: &tab)
        #expect(tab.execution.errorMessage == nil)
        #expect(tab.pagination.totalRowCount == 42)
        #expect(!tab.pagination.isApproximateRowCount)
    }

    @Test("A count that succeeds leaves an error something else put on the tab")
    func successKeepsAnotherError() {
        var tab = makeTab()
        PaginationCoordinator.applyExactCount(.failure(Throttled()), to: &tab)
        tab.execution.errorMessage = "Syntax error near FROM"

        PaginationCoordinator.applyExactCount(.success(3), to: &tab)

        #expect(tab.execution.errorMessage == "Syntax error near FROM")
    }

    @Test("A cancelled count shows nothing")
    func cancellationShowsNothing() {
        var tab = makeTab()

        PaginationCoordinator.applyExactCount(.failure(CancellationError()), to: &tab)

        #expect(tab.execution.errorMessage == nil)
    }
}
