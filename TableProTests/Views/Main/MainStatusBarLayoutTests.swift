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
    @Test("Status bar can be instantiated with nil tab")
    func instantiateWithNilTab() {
        let filterManager = FilterStateManager()
        let colVisManager = ColumnVisibilityManager()
        let view = MainStatusBarView(
            tab: nil,
            filterStateManager: filterManager,
            columnVisibilityManager: colVisManager,
            allColumns: [],
            selectedRowIndices: [],
            showStructure: .constant(false),
            onFirstPage: {},
            onPreviousPage: {},
            onNextPage: {},
            onLastPage: {},
            onLimitChange: { _ in },
            onOffsetChange: { _ in },
            onPaginationGo: {}
        )
        // Smoke test: view constructs without error
        #expect(type(of: view.body) != Never.self)
    }
}
