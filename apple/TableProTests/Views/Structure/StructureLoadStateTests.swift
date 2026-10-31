//
//  StructureLoadStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct StructureLoadStateTests {
    @Test("A fresh state has no data and needs every part fetched")
    func freshStateNeedsFetch() {
        let state = StructureLoadState()

        for item in StructureLoadState.Item.allCases {
            #expect(!state.hasData(item))
            #expect(state.needsFetch(item))
            #expect(state.failure(item) == nil)
        }
    }

    @Test("markFetched records data and clears the fetch requirement")
    func markFetchedRecordsData() {
        var state = StructureLoadState()
        state.markFetched(.indexes)

        #expect(state.hasData(.indexes))
        #expect(!state.needsFetch(.indexes))
        #expect(!state.hasData(.columns))
    }

    @Test("markAllStale keeps counts on screen while requiring a refetch")
    func markAllStaleKeepsData() {
        var state = StructureLoadState()
        state.markFetched(.columns)
        state.markFetched(.indexes)
        state.markFetched(.foreignKeys)

        state.markAllStale()

        for item in [StructureLoadState.Item.columns, .indexes, .foreignKeys] {
            #expect(state.hasData(item))
            #expect(state.needsFetch(item))
        }
    }

    @Test("Refetching a stale part clears only that part's staleness")
    func refetchClearsSinglePart() {
        var state = StructureLoadState()
        state.markFetched(.columns)
        state.markFetched(.ddl)
        state.markAllStale()

        state.markFetched(.columns)

        #expect(!state.needsFetch(.columns))
        #expect(state.needsFetch(.ddl))
        #expect(state.hasData(.ddl))
    }

    @Test("reset drops the data and the failures so a different table starts cold")
    func resetDropsData() {
        var state = StructureLoadState()
        state.markFetched(.columns)
        state.markFailed(.triggers, message: "permission denied")
        state.markAllStale()

        state.reset()

        #expect(!state.hasData(.columns))
        #expect(state.needsFetch(.columns))
        #expect(state.failures.isEmpty)
    }

    // One failed read used to blank every sub-tab, and a failed triggers read showed as "No Triggers".
    @Test("A failed read is reported for its own part only, and keeps what that part had loaded")
    func failureIsPerItem() {
        var state = StructureLoadState()
        state.markFetched(.columns)
        state.markFetched(.triggers)

        state.markFailed(.triggers, message: "permission denied")

        #expect(state.failure(.triggers) == "permission denied")
        #expect(state.hasData(.triggers))
        #expect(state.needsFetch(.triggers))
        #expect(state.failure(.columns) == nil)
        #expect(!state.needsFetch(.columns))
        #expect(state.failures == [.triggers: "permission denied"])
    }

    @Test("A first read that fails has no data, says why, and is fetched again")
    func firstReadFailure() {
        var state = StructureLoadState()

        state.markFailed(.ddl, message: "timed out")

        #expect(!state.hasData(.ddl))
        #expect(state.failure(.ddl) == "timed out")
        #expect(state.needsFetch(.ddl))
    }

    @Test("Several parts can fail at once, each with its own message")
    func failuresAreIndependent() {
        var state = StructureLoadState()

        state.markFailed(.indexes, message: "no index access")
        state.markFailed(.checkConstraints, message: "no catalog access")

        #expect(state.failure(.indexes) == "no index access")
        #expect(state.failure(.checkConstraints) == "no catalog access")
        #expect(state.failure(.foreignKeys) == nil)
    }

    @Test("A read that lands clears that part's failure")
    func fetchClearsFailure() {
        var state = StructureLoadState()
        state.markFailed(.foreignKeys, message: "timed out")
        state.markFailed(.indexes, message: "timed out")

        state.markFetched(.foreignKeys)

        #expect(state.failure(.foreignKeys) == nil)
        #expect(!state.needsFetch(.foreignKeys))
        #expect(state.failure(.indexes) == "timed out")
    }

    @Test("Marking everything stale keeps the failures on screen")
    func staleKeepsFailures() {
        var state = StructureLoadState()
        state.markFetched(.columns)
        state.markFailed(.columns, message: "timed out")

        state.markAllStale()

        #expect(state.failure(.columns) == "timed out")
        #expect(state.hasData(.columns))
    }

    @Test("Each section reads into its own part")
    func sectionMapsToItsItem() {
        #expect(StructureLoadState.Item(StructureSection.columns) == .columns)
        #expect(StructureLoadState.Item(StructureSection.indexes) == .indexes)
        #expect(StructureLoadState.Item(StructureSection.foreignKeys) == .foreignKeys)
        #expect(StructureLoadState.Item(StructureSection.checkConstraints) == .checkConstraints)
    }
}
