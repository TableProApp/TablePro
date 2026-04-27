//
//  MainStatusBarLayoutTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
import Testing

@testable import TablePro

@Suite("MainStatusBarView Layout")
@MainActor
struct MainStatusBarLayoutTests {
    @Test("Status bar can be instantiated with empty snapshot")
    func instantiateWithEmptySnapshot() {
        let filterManager = FilterStateManager()
        let colVisManager = ColumnVisibilityManager()
        let view = MainStatusBarView(
            snapshot: StatusBarSnapshot(tab: nil, buffer: nil),
            filterStateManager: filterManager,
            columnVisibilityManager: colVisManager,
            allColumns: [],
            selectedRowIndices: [],
            viewMode: .constant(.data),
            onFirstPage: {},
            onPreviousPage: {},
            onNextPage: {},
            onLastPage: {},
            onLimitChange: { _ in },
            onOffsetChange: { _ in },
            onPaginationGo: {}
        )
        #expect(type(of: view.body) != Never.self)
    }
}
