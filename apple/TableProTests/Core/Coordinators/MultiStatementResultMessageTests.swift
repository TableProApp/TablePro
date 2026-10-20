import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct MultiStatementResultMessageTests {
    private func present(_ results: [ResultSet], notice: String?) {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT 1; SELECT 2", tabType: .query))
        fixture.coordinator.queryExecutionCoordinator.presentMultiStatementResults(
            tabId: tab.id,
            timing: PluginQueryTiming(total: 0),
            totalRowsAffected: 0,
            newResultSets: results,
            sessionNotice: notice
        )
    }

    @Test("Each result of a batch carries the batch's notice after its own message")
    func noticeTravelsWithEachResult() {
        let first = ResultSet(label: "Result 1", tableRows: TableRows())
        first.statusMessage = "Consistency: ONE"
        let second = ResultSet(label: "Result 2", tableRows: TableRows())

        present([first, second], notice: "The open transaction was not committed.")

        #expect(first.statusMessage == "Consistency: ONE The open transaction was not committed.")
        #expect(second.statusMessage == "The open transaction was not committed.")
    }

    @Test("A batch with no notice leaves each result's own message as the driver gave it")
    func noNoticeKeepsEachMessage() {
        let first = ResultSet(label: "Result 1", tableRows: TableRows())
        first.statusMessage = "Consistency: ONE"
        let second = ResultSet(label: "Result 2", tableRows: TableRows())

        present([first, second], notice: nil)

        #expect(first.statusMessage == "Consistency: ONE")
        #expect(second.statusMessage == nil)
    }
}
