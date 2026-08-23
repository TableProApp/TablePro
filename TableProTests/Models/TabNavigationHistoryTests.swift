import Foundation
import Testing

@testable import TablePro

@Suite("TabNavigationHistory")
struct TabNavigationHistoryTests {
    private func makeEntry(
        table: String,
        page: Int = 1,
        filterValue: String? = nil,
        anchor: [String: String]? = nil
    ) -> TabNavigationEntry {
        var filterState = TabFilterState()
        if let filterValue {
            filterState.filters = [TableFilter(columnName: "id", filterOperator: .equal, value: filterValue)]
            filterState.commit = .all
        }
        return TabNavigationEntry(
            tableName: table,
            databaseName: "db",
            schemaName: nil,
            isView: false,
            resultsViewMode: .data,
            filterState: filterState,
            sortColumns: [],
            page: page,
            pageSize: 100,
            anchorRowKey: anchor
        )
    }

    @Test("A fresh history can go neither way")
    func freshHistoryIsEmpty() {
        let history = TabNavigationHistory()
        #expect(history.canGoBack == false)
        #expect(history.canGoForward == false)
    }

    @Test("Recording a location makes Back available and leaves Forward empty")
    func recordEnablesBack() {
        var history = TabNavigationHistory()
        history.record(makeEntry(table: "orders"))
        #expect(history.canGoBack)
        #expect(history.canGoForward == false)
    }

    @Test("Back returns the recorded location and puts the current one on Forward")
    func backReturnsRecordedLocation() {
        var history = TabNavigationHistory()
        history.record(makeEntry(table: "orders", page: 3))

        let returned = history.stepBack(from: makeEntry(table: "customers", filterValue: "42"))

        #expect(returned?.tableName == "orders")
        #expect(returned?.page == 3)
        #expect(history.canGoBack == false)
        #expect(history.canGoForward)
    }

    @Test("Forward returns to the location Back left")
    func forwardReturnsToTheLocationBackLeft() {
        var history = TabNavigationHistory()
        history.record(makeEntry(table: "orders"))
        let current = makeEntry(table: "customers", filterValue: "42")
        _ = history.stepBack(from: current)

        let returned = history.stepForward(from: makeEntry(table: "orders"))

        #expect(returned?.tableName == "customers")
        #expect(returned?.filterState.appliedFilters.first?.value == "42")
        #expect(history.canGoBack)
        #expect(history.canGoForward == false)
    }

    @Test("Back walks one hop at a time through a chain")
    func backWalksTheChain() {
        var history = TabNavigationHistory()
        history.record(makeEntry(table: "orders"))
        history.record(makeEntry(table: "customers"))
        history.record(makeEntry(table: "addresses"))

        #expect(history.stepBack(from: makeEntry(table: "countries"))?.tableName == "addresses")
        #expect(history.stepBack(from: makeEntry(table: "addresses"))?.tableName == "customers")
        #expect(history.stepBack(from: makeEntry(table: "customers"))?.tableName == "orders")
        #expect(history.canGoBack == false)
    }

    @Test("A new location after Back discards the forward stack")
    func recordTruncatesForward() {
        var history = TabNavigationHistory()
        history.record(makeEntry(table: "orders"))
        _ = history.stepBack(from: makeEntry(table: "customers"))
        #expect(history.canGoForward)

        history.record(makeEntry(table: "orders"))

        #expect(history.canGoForward == false)
        #expect(history.canGoBack)
    }

    @Test("Back on an empty history returns nothing and records nothing")
    func backOnEmptyHistoryIsANoOp() {
        var history = TabNavigationHistory()
        #expect(history.stepBack(from: makeEntry(table: "orders")) == nil)
        #expect(history.canGoForward == false)
    }

    @Test("Forward on an empty history returns nothing and records nothing")
    func forwardOnEmptyHistoryIsANoOp() {
        var history = TabNavigationHistory()
        #expect(history.stepForward(from: makeEntry(table: "orders")) == nil)
        #expect(history.canGoBack == false)
    }

    @Test("The stack is capped and drops its oldest entry")
    func stackIsCapped() {
        var history = TabNavigationHistory()
        for index in 0...TabNavigationHistory.maxDepth {
            history.record(makeEntry(table: "table_\(index)"))
        }

        var seen: [String] = []
        while let entry = history.stepBack(from: makeEntry(table: "current")) {
            seen.append(entry.tableName)
        }

        #expect(seen.count == TabNavigationHistory.maxDepth)
        #expect(seen.first == "table_\(TabNavigationHistory.maxDepth)")
        #expect(seen.last == "table_1")
    }

    @Test("An entry carries the row anchor back with it")
    func entryCarriesRowAnchor() {
        var history = TabNavigationHistory()
        history.record(makeEntry(table: "orders", anchor: ["id": "4021"]))

        let returned = history.stepBack(from: makeEntry(table: "customers"))

        #expect(returned?.anchorRowKey == ["id": "4021"])
    }
}
