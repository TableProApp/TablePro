//
//  ResultPaneProjectionStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ResultPaneProjectionStateTests {
    private struct Key: ResultPaneProjectionKey {
        let tabId: UUID
        let resultSetId: UUID
        let column: String
        let revision: Int

        var subject: [AnyHashable] { [tabId, column] }
    }

    private let tab = UUID()

    @Test("A refresh, sort or page turn keeps the drawing up while its replacement builds")
    func refreshKeepsTheProjection() {
        var state = ResultPaneProjectionState<String, Key>()
        state.commit("first", for: Key(tabId: tab, resultSetId: UUID(), column: "revenue", revision: 1))
        let refreshed = Key(tabId: tab, resultSetId: UUID(), column: "revenue", revision: 2)

        #expect(state.projection(for: refreshed) == "first")
        #expect(!state.isCurrent(for: refreshed))
    }

    @Test("Another tab or other columns never show this projection")
    func otherSubjectsShowNothing() {
        var state = ResultPaneProjectionState<String, Key>()
        let result = UUID()
        state.commit("first", for: Key(tabId: tab, resultSetId: result, column: "revenue", revision: 1))

        #expect(state.projection(for: Key(tabId: UUID(), resultSetId: result, column: "revenue", revision: 1)) == nil)
        #expect(state.projection(for: Key(tabId: tab, resultSetId: result, column: "cost", revision: 1)) == nil)
    }

    @Test("The key it was built for needs no rebuild")
    func exactKeyIsCurrent() {
        var state = ResultPaneProjectionState<String, Key>()
        let key = Key(tabId: tab, resultSetId: UUID(), column: "revenue", revision: 1)

        #expect(state.projection(for: key) == nil)
        state.commit("first", for: key)
        #expect(state.isCurrent(for: key))
        #expect(state.projection(for: key) == "first")
    }

    @Test("A chart keeps its drawing across a new result set with the same columns")
    func chartSubjectIgnoresTheResultSet() {
        let tab = UUID()
        let first = ResultChartProjectionKey(tabId: tab, resultSetId: UUID(), dataRevision: 1, resolved: nil, isUnlocked: true)
        let second = ResultChartProjectionKey(tabId: tab, resultSetId: UUID(), dataRevision: 2, resolved: nil, isUnlocked: true)

        #expect(first.subject == second.subject)
        #expect(first != second)
    }
}
