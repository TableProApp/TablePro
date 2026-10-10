//
//  ContainerChangeRerunPolicyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ContainerChangeRerunPolicyTests {
    private func rowResult() -> ResultSet {
        ResultSet(
            label: "Result 1",
            tableRows: TableRows.from(queryRows: [[.text("1")]], columns: ["id"], columnTypes: [.text(rawType: "INTEGER")])
        )
    }

    @Test("A tab showing rows reruns on the new database")
    func rowResultReruns() {
        #expect(ContainerChangeRerunPolicy.reruns(showing: rowResult()))
    }

    @Test("A tab with no result does not run")
    func noResultDoesNotRun() {
        #expect(!ContainerChangeRerunPolicy.reruns(showing: nil))
    }

    @Test("A tab showing an error does not rerun")
    func errorDoesNotRerun() {
        let failed = rowResult()
        failed.errorMessage = "Table 'shop.orders' doesn't exist"

        #expect(!ContainerChangeRerunPolicy.reruns(showing: failed))
    }

    @Test("A tab showing a plan does not rerun")
    func explainDoesNotRerun() {
        let plan = ExplainResultSetFactory.make(
            rawText: "Seq Scan on orders",
            plan: nil,
            sql: "EXPLAIN SELECT * FROM orders",
            executionTime: nil
        )
        plan.tableRows = TableRows.from(queryRows: [[.text("1")]], columns: ["QUERY PLAN"], columnTypes: [.text(rawType: "TEXT")])

        #expect(!ContainerChangeRerunPolicy.reruns(showing: plan))
    }

    @Test("A tab showing a write's affected-row count does not rerun")
    func writeResultDoesNotRerun() {
        let write = ResultSet(label: "Result 1")
        write.rowsAffected = 3
        write.statusMessage = "3 rows affected"

        #expect(!ContainerChangeRerunPolicy.reruns(showing: write))
    }
}
