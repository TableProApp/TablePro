//
//  StructureTabDataStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("StructureTabDataState")
struct StructureTabDataStateTests {
    @Test("a fresh state has no data and needs every tab fetched")
    func freshStateNeedsFetch() {
        let state = StructureTabDataState()

        for tab in StructureTab.allCases {
            #expect(!state.hasData(tab))
            #expect(state.needsFetch(tab))
        }
    }

    @Test("markFetched records data and clears the fetch requirement")
    func markFetchedRecordsData() {
        var state = StructureTabDataState()
        state.markFetched(.indexes)

        #expect(state.hasData(.indexes))
        #expect(!state.needsFetch(.indexes))
        #expect(!state.hasData(.columns))
    }

    @Test("markAllStale keeps counts on screen while requiring a refetch")
    func markAllStaleKeepsData() {
        var state = StructureTabDataState()
        state.markFetched(.columns)
        state.markFetched(.indexes)
        state.markFetched(.foreignKeys)

        state.markAllStale()

        for tab in [StructureTab.columns, .indexes, .foreignKeys] {
            #expect(state.hasData(tab))
            #expect(state.needsFetch(tab))
        }
    }

    @Test("refetching a stale tab clears only that tab's staleness")
    func refetchClearsSingleTab() {
        var state = StructureTabDataState()
        state.markFetched(.columns)
        state.markFetched(.ddl)
        state.markAllStale()

        state.markFetched(.columns)

        #expect(!state.needsFetch(.columns))
        #expect(state.needsFetch(.ddl))
        #expect(state.hasData(.ddl))
    }

    @Test("reset drops the data so a different table starts cold")
    func resetDropsData() {
        var state = StructureTabDataState()
        state.markFetched(.columns)
        state.markAllStale()

        state.reset()

        #expect(!state.hasData(.columns))
        #expect(state.needsFetch(.columns))
    }

    @Test("a tab with data renders its count, a tab without renders a bare name")
    func labelIncludesCountOnlyWhenLoaded() {
        let withCount = StructureTabDataState.label(for: .indexes, count: 4)
        let withoutCount = StructureTabDataState.label(for: .indexes, count: nil)

        #expect(withCount == "\(StructureTab.indexes.displayName) (4)")
        #expect(withoutCount == StructureTab.indexes.displayName)
        #expect(withCount != withoutCount)
    }

    @Test("a zero count still renders, so the label never collapses to a bare name")
    func labelRendersZeroCount() {
        #expect(StructureTabDataState.label(for: .foreignKeys, count: 0)
            == "\(StructureTab.foreignKeys.displayName) (0)")
    }
}
