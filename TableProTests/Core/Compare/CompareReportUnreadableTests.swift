//
//  CompareReportUnreadableTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A table whose metadata could not be read has no snapshot, so the diff engine sees it on one side
/// only and suggests dropping it, while the row carrying the reason sits beside it under Could Not
/// Compare. Generating a script from that state wrote `DROP TABLE` against the target for a table
/// the comparison never managed to read.
@Suite("Compare report over an unreadable object")
struct CompareReportUnreadableTests {
    private func identity(_ name: String) -> CompareObjectIdentity {
        CompareObjectIdentity(kind: .table, schema: nil, name: name)
    }

    private func onlyInTarget(_ name: String) -> CompareObjectResult {
        CompareObjectResult(identity: identity(name), status: .onlyInTarget)
    }

    private func unreadable(_ name: String) -> CompareObjectResult {
        CompareObjectResult(identity: identity(name), status: .differs, comparisonError: "read failed")
    }

    @Test("The reason wins over the difference inferred from the object's absence")
    func unreadableObjectIsNotAlsoADifference() throws {
        let report = CompareReport(results: [onlyInTarget("orders"), unreadable("orders")])

        let orders = report.results.filter { $0.id == identity("orders").id }
        #expect(orders.count == 1)
        #expect(orders.first?.comparisonError == "read failed")
        #expect(orders.first?.availableActions == [.skip])
        #expect(report.comparable.isEmpty)
    }

    @Test("An object that was read keeps its difference and its actions")
    func readableObjectIsUnaffected() {
        let report = CompareReport(results: [onlyInTarget("orders"), unreadable("invoices")])

        #expect(report.comparable.map(\.id) == [identity("orders").id])
        #expect(report.comparable.first?.suggestedAction == .drop)
        #expect(report.uncomparable.map(\.id) == [identity("invoices").id])
    }
}
