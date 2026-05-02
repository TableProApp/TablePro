//
//  MainStatusBarLayoutTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("MainStatusBarView Layout")
@MainActor
struct MainStatusBarLayoutTests {
    @Test("Status bar can be instantiated with empty snapshot")
    func instantiateWithEmptySnapshot() {
        let view = MainStatusBarView(
            snapshot: StatusBarSnapshot(tab: nil, tableRows: nil),
            hiddenColumns: [],
            allColumns: [],
            selectedRowIndices: [],
            viewMode: .constant(.data),
            onFirstPage: {},
            onPreviousPage: {},
            onNextPage: {},
            onLastPage: {},
            onLimitChange: { _ in },
            onOffsetChange: { _ in },
            onPaginationGo: {},
            onToggleColumn: { _ in },
            onShowAllColumns: {},
            onHideAllColumns: { _ in }
        )
        #expect(type(of: view.body) != Never.self)
    }
}
