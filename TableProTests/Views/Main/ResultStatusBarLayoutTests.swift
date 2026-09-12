//
//  ResultStatusBarLayoutTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import TablePro

/// Every width from a wide window down well past the narrowest pane the window can produce.
///
/// The pane's floor is `defaultDetailMinThickness`, 400pt, and it cannot go below that:
/// `NSSplitViewItem.minimumThickness` is a required constraint, measured to hold against both a
/// window resize and a divider drag. The ladder's narrowest tier holds its shape down to 280pt, so
/// the widths below 380 are the recorded margin rather than states the window can reach.
///
/// File scope rather than a member: `@Test(arguments:)` reads its arguments from a nonisolated
/// context, which cannot touch a static on a `@MainActor` suite.
private let statusBarHostWidths: [CGFloat] = [1_400, 1_200, 900, 720, 600, 500, 440, 400, 380, 320, 300]

@Suite("ResultStatusBar Layout")
@MainActor
struct ResultStatusBarLayoutTests {
    private func makeBar(
        rowCount: Int,
        hasColumns: Bool,
        tabType: TabType?,
        viewMode: ResultsViewMode,
        pagination: PaginationState = PaginationState(),
        statusMessage: String? = nil,
        structureFooter: StructureFooterCapability = StructureFooterCapability()
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
            hasStructureActions: structureFooter.isActive,
            pagination: pagination,
            statusMessage: statusMessage
        )
        return ResultStatusBar(
            model: ResultStatusModel(snapshot: snapshot, viewMode: viewMode, selectedRowCount: 0),
            snapshot: snapshot,
            filterState: TabFilterState(),
            columnState: StatusBarColumnState(
                hidden: [],
                columns: [
                    GridColumnEntry(name: "id", dataIndex: 0, typeName: "INTEGER", position: 1, isHidden: false),
                    GridColumnEntry(name: "name", dataIndex: 1, typeName: "TEXT", position: 2, isHidden: false)
                ],
                onToggle: { _ in },
                onShowAll: {},
                onHideAll: { _ in },
                onReset: {},
                onJumpToColumn: nil
            ),
            highlightState: StatusBarHighlightState(
                rules: [],
                columns: hasColumns ? ["id", "name"] : [],
                isPersisted: tabType == .table,
                presentationRequest: 0,
                onChange: { _ in },
                onDismiss: {}
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
            structureFooter: structureFooter,
            execution: ExecutionReadout(
                tabId: UUID(),
                execution: TabExecutionRegistry(),
                lastTiming: nil,
                onCancel: {}
            ),
            isRefreshingSchema: false,
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

    /// The reported bug rendered as motion: clicking between tables collapsed the bar to two
    /// controls and refilled it in waves. Measuring the hosted view at each instant of that sequence
    /// is the view-level counterpart to the control-set invariance asserted in ResultStatusModelTests.
    @Test("The bar keeps its footprint at every instant of a table reload")
    func heightIsConstantAcrossAReload() {
        var loading = PaginationState(pageSize: 1_000)
        loading.isLoading = true

        var counting = PaginationState(pageSize: 1_000)
        counting.isCountPending = true

        var estimated = PaginationState(totalRowCount: 4_000_000, pageSize: 1_000)
        estimated.isApproximateRowCount = true

        let heights = [
            makeBar(rowCount: 1_000, hasColumns: true, tabType: .table, viewMode: .data,
                    pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000)),
            makeBar(rowCount: 0, hasColumns: false, tabType: .table, viewMode: .data, pagination: loading),
            makeBar(rowCount: 1_000, hasColumns: true, tabType: .table, viewMode: .data, pagination: counting),
            makeBar(rowCount: 1_000, hasColumns: true, tabType: .table, viewMode: .data, pagination: estimated),
            makeBar(rowCount: 1_000, hasColumns: true, tabType: .table, viewMode: .data,
                    pagination: PaginationState(totalRowCount: 3_812_004, pageSize: 1_000)),
        ].map(measuredHeight)

        #expect(Set(heights).count == 1, "the bar changed height while a table reloaded")
        #expect(heights.allSatisfy { $0 >= StatusBarChrome.height })
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

    // MARK: - Width

    private static let wordyDriverMessage = """
    ERROR: relation "public.some_extremely_long_table_name_nobody_would_choose" does not exist \
    at character 15
    """

    /// The bar must never report a width larger than the pane hosting it.
    ///
    /// This is the defect in one assertion. Both of the bar's clusters were pinned with
    /// `.fixedSize()`, so on a table tab in Data mode it wanted 766pt. The tab content column
    /// adopted that width, `sizingOptions = []` kept the need invisible to Auto Layout, and SwiftUI
    /// centred the oversized column inside the 440pt pane the window's own 720pt minimum leaves:
    /// 163pt was unreachable at each edge, taking the grid's row numbers, its whole first column and
    /// the entire pagination cluster with it.
    @Test("The bar is never wider than its host", arguments: statusBarHostWidths)
    func barNeverExceedsItsHost(width: CGFloat) {
        let bar = makeBar(
            rowCount: 1_000,
            hasColumns: true,
            tabType: .table,
            viewMode: .data,
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000)
        )
        expectFills(bar, at: width)
    }

    @Test("The structure editor's bar is never wider than its host", arguments: statusBarHostWidths)
    func structureBarNeverExceedsItsHost(width: CGFloat) {
        let bar = makeBar(
            rowCount: 1_000,
            hasColumns: true,
            tabType: .table,
            viewMode: .structure,
            structureFooter: StructureFooterCapability(
                canAdd: true,
                canRemove: true,
                addLabel: "Add Column",
                removeLabel: "Remove Column"
            )
        )
        expectFills(bar, at: width)
    }

    @Test("A query tab's bar is never wider than its host", arguments: statusBarHostWidths)
    func queryBarNeverExceedsItsHost(width: CGFloat) {
        let bar = makeBar(
            rowCount: 1_000,
            hasColumns: true,
            tabType: .query,
            viewMode: .data,
            pagination: PaginationState(pageSize: 1_000)
        )
        expectFills(bar, at: width)
    }

    /// A wordy driver message must truncate rather than widen the bar. It is also why the readout
    /// reports a constant ideal width: `ViewThatFits` chooses on a candidate's ideal size, so a width
    /// read off the sentence would drop the whole bar a tier by itself.
    @Test("A wordy driver message does not widen the bar", arguments: statusBarHostWidths)
    func wordyStatusMessageDoesNotWidenTheBar(width: CGFloat) {
        let bar = makeBar(
            rowCount: 1_000,
            hasColumns: true,
            tabType: .table,
            viewMode: .data,
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000),
            statusMessage: Self.wordyDriverMessage
        )
        expectFills(bar, at: width)
    }

    /// The narrowest tier has to fit the narrowest pane the window can produce, or `ViewThatFits`
    /// falls through to a row that overflows anyway. `resolveDetailMinimumThickness` sets that
    /// floor, so the two are checked against each other rather than against a literal that could
    /// drift away from either.
    @Test("The narrowest tier fits the narrowest pane the window allows")
    func narrowestTierFitsTheNarrowestPane() {
        let pane = MainSplitViewController.defaultDetailMinThickness
        let bar = makeBar(
            rowCount: 1_000,
            hasColumns: true,
            tabType: .table,
            viewMode: .data,
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000)
        )
        expectFills(bar, at: pane)
    }

    /// The grid shares a `VStack` with the bar, closed by a `.frame(maxWidth: .infinity)` that can
    /// never report less than its widest child, which is how the bar's width reached the grid at
    /// all. Measuring the column rather than the bar alone is what pins that path.
    @Test("The content column around the bar is never wider than its host", arguments: statusBarHostWidths)
    func contentColumnNeverExceedsItsHost(width: CGFloat) {
        let bar = makeBar(
            rowCount: 1_000,
            hasColumns: true,
            tabType: .table,
            viewMode: .data,
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000)
        )
        let column = VStack(spacing: 0) {
            Color.clear
            bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        expectFills(column, at: width)
    }

    private func expectFills(_ content: some View, at width: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) {
        let measured = measureFrame(of: content, at: width)
        #expect(measured.width == width, "the bar reported \(measured.width)pt inside a \(width)pt host", sourceLocation: sourceLocation)
        #expect(measured.minX == 0, "the bar was placed at \(measured.minX) instead of the host's leading edge", sourceLocation: sourceLocation)
    }

    /// Where the content actually landed inside its host.
    ///
    /// A marker view rather than a rasterised image: SwiftUI draws these controls with no child
    /// `NSView`s of their own, so walking the view tree finds nothing, and an offscreen bitmap of an
    /// AppKit container reports its own artefacts. `sizingOptions = []` mirrors `WorkspacePanes`,
    /// and it is the reason the defect is visible here at all: without it the host would simply grow
    /// to whatever the bar asked for.
    private func measureFrame(of content: some View, at width: CGFloat) -> CGRect {
        let box = StatusBarFrameBox()
        let host = NSHostingView(rootView: AnyView(content.overlay(StatusBarFrameProbe(box: box))))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        host.layoutSubtreeIfNeeded()
        #expect(box.hostWidth == width, "the probe did not run inside a \(width)pt host")
        return box.frame ?? CGRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan)
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

@MainActor
private final class StatusBarFrameBox {
    var frame: CGRect?
    var hostWidth: CGFloat?
}

private struct StatusBarFrameProbe: NSViewRepresentable {
    let box: StatusBarFrameBox

    func makeNSView(context: Context) -> NSView { ProbeView(box: box) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        private let box: StatusBarFrameBox

        init(box: StatusBarFrameBox) {
            self.box = box
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("StatusBarFrameProbe does not support NSCoder init")
        }

        override func layout() {
            super.layout()
            guard let host = enclosingHostingView() else { return }
            let measured = convert(bounds, to: host)
            let hostWidth = host.bounds.width
            MainActor.assumeIsolated {
                box.frame = measured
                box.hostWidth = hostWidth
            }
        }

        private func enclosingHostingView() -> NSView? {
            var candidate: NSView? = self
            while let current = candidate {
                if String(describing: type(of: current)).contains("NSHostingView") { return current }
                candidate = current.superview
            }
            return nil
        }
    }
}
