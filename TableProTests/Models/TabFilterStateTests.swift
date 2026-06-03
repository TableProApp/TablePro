//
//  TabFilterStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TabFilterState")
struct TabFilterStateTests {
    @Test("appliedFilters is empty when nothing is committed")
    func noCommitYieldsEmpty() {
        var state = TabFilterState()
        state.filters = [TestFixtures.makeTableFilter(column: "id")]
        #expect(state.commit == nil)
        #expect(state.appliedFilters.isEmpty)
        #expect(!state.hasAppliedFilters)
    }

    @Test("commit .all excludes disabled and invalid filters")
    func commitAllExcludesDisabledAndInvalid() {
        let active = TestFixtures.makeTableFilter(column: "id", value: "1")
        let disabled = TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        let invalid = TestFixtures.makeTableFilter(column: "", value: "")
        var state = TabFilterState()
        state.filters = [active, disabled, invalid]
        state.commit = .all
        #expect(state.appliedFilters == [active])
    }

    @Test("commit .solo returns only that filter, forced active even if it was disabled")
    func commitSoloForcesActive() {
        let other = TestFixtures.makeTableFilter(column: "id", value: "1")
        let target = TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        var state = TabFilterState()
        state.filters = [other, target]
        state.commit = .solo(target.id)
        #expect(state.appliedFilters.map(\.id) == [target.id])
        #expect(state.appliedFilters.first?.isEnabled == true)
    }

    @Test("commit .solo on a missing id yields empty")
    func commitSoloMissingIdYieldsEmpty() {
        var state = TabFilterState()
        state.filters = [TestFixtures.makeTableFilter(column: "id")]
        state.commit = .solo(UUID())
        #expect(state.appliedFilters.isEmpty)
    }

    @Test("appliedFilters tracks filters automatically with no separate write")
    func appliedFiltersDerivesFromFilters() {
        let first = TestFixtures.makeTableFilter(column: "id", value: "1")
        let second = TestFixtures.makeTableFilter(column: "name", value: "a")
        var state = TabFilterState()
        state.filters = [first, second]
        state.commit = .all
        #expect(state.appliedFilters.count == 2)

        state.filters.removeAll { $0.id == second.id }
        #expect(state.appliedFilters == [first])
    }

    @Test("TabFilterState round-trips through Codable including the solo commit")
    func codableRoundTrip() throws {
        let filter = TestFixtures.makeTableFilter(column: "id", value: "1")
        var state = TabFilterState(isVisible: true)
        state.filters = [filter]
        state.commit = .solo(filter.id)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TabFilterState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.appliedFilters.map(\.id) == [filter.id])
    }
}
