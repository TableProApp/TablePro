//
//  ResultStatusBarLayoutTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import TablePro

@Suite("ResultStatusBar Layout")
@MainActor
struct ResultStatusBarLayoutTests {
    private func makeBar(
        rowCount: Int,
        hasColumns: Bool,
        tabType: TabType?,
        viewMode: ResultsViewMode,
        pagination: PaginationState = PaginationState()
    ) -> ResultStatusBar {
        let snapshot = StatusBarSnapshot(
            tabId: UUID(),
            tabType: tabType,
            hasRows: rowCount > 0,
            hasColumns: hasColumns,
            rowCount: rowCount,
            hasTableName: tabType == .table,
            availableModes: ResultsModeAvailability.modes(
                tabType: tabType,
                hasTableName: tabType == .table,
                hasColumns: hasColumns
            ),
            pagination: pagination,
            statusMessage: nil
        )
        return ResultStatusBar(
            model: ResultStatusModel(snapshot: snapshot, viewMode: viewMode, selectedRowCount: 0),
            snapshot: snapshot,
            filterState: TabFilterState(),
            columnState: StatusBarColumnState(
                hidden: [],
                all: ["id", "name"],
                onToggle: { _ in },
                onShowAll: {},
                onHideAll: { _ in },
                onReset: {}
            ),
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
            structureFooter: StructureFooterCapability(),
            viewMode: .constant(viewMode),
            onToggleFilters: {},
            onFetchAll: {},
            onStructureAdd: {},
            onStructureRemove: {}
        )
    }

    private func measuredHeight(of bar: ResultStatusBar) -> CGFloat {
        let host = NSHostingView(rootView: bar)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// A fresh query tab used to render an 8pt sliver that snapped to 28pt on the first execution,
    /// shoving the grid up by 20pt every time.
    @Test("The bar is the same height before and after a result arrives")
    func heightIsConstantAcrossResultStates() {
        let empty = measuredHeight(of: makeBar(
            rowCount: 0, hasColumns: false, tabType: .query, viewMode: .data
        ))
        let populated = measuredHeight(of: makeBar(
            rowCount: 1_000,
            hasColumns: true,
            tabType: .table,
            viewMode: .data,
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000)
        ))
        #expect(empty == populated)
        #expect(empty >= StatusBarChrome.height)
    }

    @Test("The bar is the same height in every result mode")
    func heightIsConstantAcrossModes() {
        let pagination = PaginationState(totalRowCount: 5_000, pageSize: 1_000)
        let heights = [ResultsViewMode.data, .structure, .json, .chart].map { mode in
            measuredHeight(of: makeBar(
                rowCount: 1_000, hasColumns: true, tabType: .table, viewMode: mode, pagination: pagination
            ))
        }
        #expect(Set(heights).count == 1, "controls must not change the bar's height when the mode changes")
    }

    /// The switcher leads the bar in every mode, so leaving Structure never needs a control that
    /// only Structure renders.
    @Test("The mode switcher is on the bar in every mode")
    func modeSwitcherIsAlwaysReachable() {
        let pagination = PaginationState(totalRowCount: 5_000, pageSize: 1_000)
        for mode in [ResultsViewMode.data, .structure, .json, .chart] {
            let snapshot = StatusBarSnapshot(
                tabId: UUID(),
                tabType: .table,
                hasRows: true,
                hasColumns: true,
                rowCount: 1_000,
                hasTableName: true,
                availableModes: ResultsModeAvailability.modes(tabType: .table, hasTableName: true, hasColumns: true),
                pagination: pagination,
                statusMessage: nil
            )
            let model = ResultStatusModel(snapshot: snapshot, viewMode: mode, selectedRowCount: 0)
            #expect(model.controls.showsModeSwitcher)
        }
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

    @Test("The find bar belongs to the grid it searches, unlike the filter panel")
    func findBarVisibilityByMode() {
        #expect(ResultsViewMode.data.showsFindBar)
        #expect(!ResultsViewMode.json.showsFindBar)
        #expect(!ResultsViewMode.chart.showsFindBar)
        #expect(!ResultsViewMode.structure.showsFindBar)

        for mode in [ResultsViewMode.data, .json, .chart, .structure] where mode.showsFindBar {
            #expect(mode.showsRowFilters, "a mode that finds must also filter")
        }
    }
}
