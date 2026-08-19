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
                onGoToPage: { _ in },
                onRequestExactCount: {}
            ),
            columnState: StatusBarColumnState(
                hidden: [],
                all: [],
                onToggle: { _ in },
                onShowAll: {},
                onHideAll: { _ in },
                onReset: {}
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
        #expect(!MainStatusBarView.showsAddRow(viewMode: .chart, canAddRow: true))
    }

    @Test("Add Row button is hidden when adding is not allowed")
    func addRowHiddenWhenNotAllowed() {
        #expect(!MainStatusBarView.showsAddRow(viewMode: .data, canAddRow: false))
        #expect(!MainStatusBarView.showsAddRow(viewMode: .structure, canAddRow: false))
        #expect(!MainStatusBarView.showsAddRow(viewMode: .json, canAddRow: false))
        #expect(!MainStatusBarView.showsAddRow(viewMode: .chart, canAddRow: false))
    }

    @Test("Chart mode keeps the controls that decide which rows it is drawing")
    func resultScopeVisibilityByMode() {
        #expect(ResultsViewMode.data.showsResultScope)
        #expect(ResultsViewMode.json.showsResultScope)
        #expect(ResultsViewMode.chart.showsResultScope)
        #expect(!ResultsViewMode.structure.showsResultScope)
    }

    @Test("Grid-only controls stay with the grid")
    func gridControlVisibilityByMode() {
        #expect(ResultsViewMode.data.showsColumnControls)
        #expect(ResultsViewMode.json.showsColumnControls)
        #expect(!ResultsViewMode.chart.showsColumnControls)
        #expect(!ResultsViewMode.structure.showsColumnControls)

        #expect(ResultsViewMode.data.showsRowFilters)
        #expect(ResultsViewMode.json.showsRowFilters)
        #expect(!ResultsViewMode.chart.showsRowFilters)
        #expect(!ResultsViewMode.structure.showsRowFilters)
    }
}
