import Foundation
import Testing
import TableProDatabase
import TableProModels
@testable import TableProMobile

@MainActor
@Suite("QueryEditorViewModel")
struct QueryEditorViewModelTests {

    private func makeColumns() -> [ColumnInfo] {
        [ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0)]
    }

    @Test("run caps a large result and keeps the first rows")
    func runCapsAndKeepsHead() async {
        let driver = MockDatabaseDriver()
        let rows = (0..<10).map { ["\($0)"] }
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: rows, rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, query: "SELECT * FROM t", maxRows: 3)

        #expect(vm.legacyRows.count == 3)
        #expect(vm.legacyRows.first?.first == "0")
        #expect(vm.legacyRows.last?.first == "2")
        #expect(vm.truncationReason != nil)
        #expect(vm.truncationMessage != nil)
        if case .truncated(let reason) = vm.phase, case .rowCap(let cap) = reason {
            #expect(cap == 3)
        } else {
            Issue.record("expected truncated(.rowCap) phase, got \(vm.phase)")
        }
    }

    @Test("run completes without truncation for a small result")
    func runCompletes() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1"], ["2"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, query: "SELECT id FROM t", maxRows: 100)

        #expect(vm.legacyRows.count == 2)
        #expect(vm.truncationReason == nil)
        #expect(vm.truncationMessage == nil)
        if case .finished = vm.phase {} else {
            Issue.record("expected finished phase, got \(vm.phase)")
        }
    }

    @Test("memory pressure after a clean finish does not relabel the result")
    func pressureDoesNotRelabelFinishedResult() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1"], ["2"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, query: "SELECT id FROM t", maxRows: 100)
        #expect(vm.truncationReason == nil)

        await vm.handlePressure(.warning)

        #expect(vm.legacyRows.count == 2)
        #expect(vm.truncationReason == nil)
        #expect(vm.truncationMessage == nil)
        if case .finished = vm.phase {} else {
            Issue.record("a completed result must stay finished after a memory warning")
        }
    }

    @Test("reset clears rows and returns to idle")
    func resetClears() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, query: "SELECT id FROM t", maxRows: 100)
        #expect(vm.legacyRows.count == 1)

        vm.reset()

        #expect(vm.legacyRows.isEmpty)
        #expect(vm.columns.isEmpty)
        if case .idle = vm.phase {} else {
            Issue.record("expected idle phase after reset")
        }
    }
}
