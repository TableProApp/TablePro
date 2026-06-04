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
            selectedRowIndices: [],
            viewMode: .constant(.data),
            paginationCallbacks: PaginationCallbacks(
                onFirst: {},
                onPrevious: {},
                onNext: {},
                onLast: {},
                onPageSizeChange: { _ in },
                onShowAll: {},
                onGoToPage: { _ in }
            ),
            columnState: StatusBarColumnState(
                hidden: [],
                all: [],
                onToggle: { _ in },
                onShowAll: {},
                onHideAll: { _ in }
            ),
            structureState: StatusBarStructureState(
                footer: StructureFooterState(),
                onAdd: {},
                onRemove: {}
            ),
            onToggleFilters: {},
            onFetchAll: nil
        )
        #expect(type(of: view.body) != Never.self)
    }
}
