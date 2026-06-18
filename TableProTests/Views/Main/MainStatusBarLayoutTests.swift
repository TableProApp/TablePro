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
            onFetchAll: nil,
            onAddRow: nil
        )
        #expect(type(of: view.body) != Never.self)
    }

    @Test("Add Row button shows only in Data mode when adding is allowed")
    func addRowVisibilityByMode() {
        #expect(MainStatusBarView.showsAddRow(viewMode: .data, canAddRow: true))
        #expect(!MainStatusBarView.showsAddRow(viewMode: .structure, canAddRow: true))
        #expect(!MainStatusBarView.showsAddRow(viewMode: .json, canAddRow: true))
    }

    @Test("Add Row button is hidden when adding is not allowed")
    func addRowHiddenWhenNotAllowed() {
        #expect(!MainStatusBarView.showsAddRow(viewMode: .data, canAddRow: false))
        #expect(!MainStatusBarView.showsAddRow(viewMode: .structure, canAddRow: false))
        #expect(!MainStatusBarView.showsAddRow(viewMode: .json, canAddRow: false))
    }
}
