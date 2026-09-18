//
//  WelcomeListStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("WelcomeListState")
struct WelcomeListStateTests {
    private func input(
        hasAnyConnection: Bool = true,
        hasVisibleContent: Bool = false,
        searchText: String = "",
        isTagFiltered: Bool = false
    ) -> WelcomeListState.Input {
        WelcomeListState.Input(
            hasAnyConnection: hasAnyConnection,
            hasVisibleContent: hasVisibleContent,
            searchText: searchText,
            isTagFiltered: isTagFiltered
        )
    }

    @Test("Anything visible is the list, whatever narrows it")
    func contentWins() {
        #expect(
            WelcomeListState.resolve(input(hasVisibleContent: true, searchText: "prod", isTagFiltered: true))
                == .content
        )
    }

    @Test("No connection at all is the first run, whatever the search holds")
    func noConnectionIsTheFirstRun() {
        #expect(WelcomeListState.resolve(input(hasAnyConnection: false)) == .firstRun)
        #expect(WelcomeListState.resolve(input(hasAnyConnection: false, searchText: "prod")) == .firstRun)
    }

    @Test("A search that hides every connection is a search miss")
    func searchMiss() {
        #expect(WelcomeListState.resolve(input(searchText: "prod")) == .noSearchMatch("prod"))
    }

    @Test("A tag filter that hides every connection is a filter miss, not the first run")
    func filterMiss() {
        #expect(WelcomeListState.resolve(input(isTagFiltered: true)) == .noFilterMatch)
    }

    @Test("A search miss is named before a filter miss")
    func searchMissWinsOverFilterMiss() {
        #expect(WelcomeListState.resolve(input(searchText: "prod", isTagFiltered: true)) == .noSearchMatch("prod"))
    }
}
