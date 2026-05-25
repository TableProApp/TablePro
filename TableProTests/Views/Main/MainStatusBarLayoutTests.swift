//
//  MainStatusBarLayoutTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MainStatusBarView Layout")
@MainActor
struct MainStatusBarLayoutTests {
    @Test("Status bar can be instantiated with empty snapshot")
    func instantiateWithEmptySnapshot() {
        let view = MainStatusBarView(
            snapshot: StatusBarSnapshot(tab: nil, tableRows: nil),
            filterState: TabFilterState(),
            hiddenColumns: [],
            allColumns: [],
            selectedRowIndices: [],
            viewMode: .constant(.data),
            onFirstPage: {},
            onPreviousPage: {},
            onNextPage: {},
            onLastPage: {},
            onPageSizeChange: { _ in },
            onShowAll: {},
            onGoToPage: { _ in },
            onToggleColumn: { _ in },
            onShowAllColumns: {},
            onHideAllColumns: { _ in },
            onToggleFilters: {}
        )
        #expect(type(of: view.body) != Never.self)
    }
}
