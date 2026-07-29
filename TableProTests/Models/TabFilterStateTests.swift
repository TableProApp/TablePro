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

    @Test("allEnabledState is false when there are no filters")
    func allEnabledStateEmpty() {
        let state = TabFilterState()
        #expect(state.allEnabledState == false)
    }

    @Test("allEnabledState is true when every filter is enabled")
    func allEnabledStateAllOn() {
        var state = TabFilterState()
        state.filters = [
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name")
        ]
        #expect(state.allEnabledState == true)
    }

    @Test("allEnabledState is false when every filter is disabled")
    func allEnabledStateAllOff() {
        var state = TabFilterState()
        state.filters = [
            TestFixtures.makeTableFilter(column: "id", isEnabled: false),
            TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        ]
        #expect(state.allEnabledState == false)
    }

    @Test("allEnabledState is nil when filters are mixed")
    func allEnabledStateMixed() {
        var state = TabFilterState()
        state.filters = [
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        ]
        #expect(state.allEnabledState == nil)
    }

    @Test("browseSearch reads and writes the key pattern fields")
    func browseSearchAccessor() {
        var state = TabFilterState()
        #expect(!state.hasActiveBrowseSearch)

        state.browseSearch = BrowseSearchState(pattern: "user:*", typeScope: "hash")
        #expect(state.keyPattern == "user:*")
        #expect(state.keyTypeScope == "hash")
        #expect(state.hasActiveBrowseSearch)
        #expect(state.browseSearch == BrowseSearchState(pattern: "user:*", typeScope: "hash"))
    }

    @Test("A type scope alone counts as an active browse search")
    func typeScopeAloneIsActive() {
        var state = TabFilterState()
        state.browseSearch = BrowseSearchState(pattern: "", typeScope: "stream")
        #expect(state.hasActiveBrowseSearch)
    }

    @Test("Legacy JSON without key pattern fields decodes with defaults")
    func decodesLegacyJsonWithoutKeyPatternFields() throws {
        let legacy = Data("""
        {"filters":[],"isVisible":true,"filterLogicMode":"AND"}
        """.utf8)

        let decoded = try JSONDecoder().decode(TabFilterState.self, from: legacy)

        #expect(decoded.isVisible)
        #expect(decoded.keyPattern.isEmpty)
        #expect(decoded.keyTypeScope == nil)
        #expect(!decoded.hasActiveBrowseSearch)
    }

    @Test("Key pattern fields survive a Codable round-trip")
    func browseSearchRoundTrip() throws {
        var state = TabFilterState(isVisible: true)
        state.browseSearch = BrowseSearchState(pattern: "cache:*", typeScope: "string")

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TabFilterState.self, from: data)

        #expect(decoded.keyPattern == "cache:*")
        #expect(decoded.keyTypeScope == "string")
        #expect(decoded == state)
    }
}
