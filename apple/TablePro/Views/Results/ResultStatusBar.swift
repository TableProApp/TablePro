import AppKit
import SwiftUI

// Two zones: `ViewThatFits` picks the widest `StatusBarTier` that fits, and no tier drops a control that anchors a popover.
struct ResultStatusBar: View {
    @ObservedObject private var keyboard = AppSettingsManager.shared.keyboardSlice
    let model: ResultStatusModel
    let snapshot: StatusBarSnapshot
    let filterState: TabFilterState
    let columnState: StatusBarColumnState
    let highlightState: StatusBarHighlightState
    let paginationCallbacks: PaginationCallbacks
    let execution: ExecutionReadout
    // Held, not observed: only the readout inside the report slot re-renders when it changes.
    let selectionSummary: SelectionSummaryState
    let isRefreshingSchema: Bool
    @Binding var viewMode: ResultsViewMode
    // Empty unless the tab holds exactly one result: two or more are chosen from the tab row above the result.
    let resultSetMenu: ResultSetMenuModel
    let resultSetActions: ResultSetActions
    let onToggleFilters: () -> Void
    let onFetchAll: (() -> Void)?
    var autoRefresh: StatusBarAutoRefreshState = .unavailable

    @State private var showColumnPopover = false
    @State private var showHighlightPopover = false
    // By the time the close is seen this view belongs to the new tab, so pruning "the selected tab" pruned the wrong one.
    @State private var highlightPopoverTabId: UUID?
    @State private var revealedExecutionTabId: UUID?
    @State private var showSelectionSummaryPopover = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.regular)
            row(.compact)
            row(.narrow)
        }
        .loadingRevealGate(
            for: execution.tabId,
            isActive: execution.isExecuting,
            activeSince: execution.startedAt,
            revealedSubject: $revealedExecutionTabId
        )
        .statusBarChrome()
        .onChange(of: snapshot.tabId) { _ in
            showColumnPopover = false
            showHighlightPopover = false
            showSelectionSummaryPopover = false
        }
        .onChange(of: showHighlightPopover) { isShown in
            guard !isShown else {
                highlightPopoverTabId = snapshot.tabId
                return
            }
            if let tabId = highlightPopoverTabId {
                highlightState.onDismiss(tabId)
            }
            highlightPopoverTabId = nil
        }
        .onValueChange(of: highlightPresentation) { previous, current in
            guard previous.tabId == current.tabId, model.controls.showsHighlightRules else { return }
            showHighlightPopover = true
        }
    }

    // `ViewThatFits` measures each row and mounts the first that fits.
    @ViewBuilder
    private func row(_ tier: StatusBarTier) -> some View {
        let presentation = ResultStatusPresentation(tier: tier)
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if model.controls.showsModeSwitcher {
                modeSwitcher(presentation)
            }
            if !resultSetMenu.isEmpty {
                ResultSetMenu(
                    model: resultSetMenu,
                    isSpelledOut: presentation.resultSetMenuIsSpelledOut,
                    actions: resultSetActions
                )
            }
            if model.controls.showsReadout || model.controls.showsExecution {
                readoutZone(readoutCluster)
            } else {
                Spacer(minLength: 0)
            }
            controlCluster(presentation)
        }
    }

    // Capped: the pull-down takes its widest item's width, and a long locale would set the narrow tier's floor.
    @ViewBuilder
    private func modeSwitcher(_ presentation: ResultStatusPresentation) -> some View {
        let picker = Picker(String(localized: "View Mode"), selection: $viewMode) {
            ForEach(snapshot.availableModes, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .accessibilityIdentifier("results-view-mode-picker")

        if presentation.modeSwitcherIsSegmented {
            picker
                .viewSwitcherStyle()
                .fixedSize()
        } else {
            picker
                .pickerStyle(.menu)
                .frame(maxWidth: StatusBarLayoutMetrics.modeMenuMaximumWidth)
        }
    }

    // Takes the bar's slack; the clusters on either side keep their intrinsic widths.
    private var readoutCluster: some View {
        ReadoutZoneLayout(spacing: StatusBarChrome.clusterSpacing, sentenceIdealWidth: StatusBarLayoutMetrics.readoutIdealWidth) {
            HStack(spacing: Self.readoutSpacing) {
                if model.controls.showsReadout {
                    readoutSentence
                }
            }
            HStack(spacing: Self.readoutSpacing) {
                if model.controls.showsReadout {
                    readoutActions
                }
            }
            HStack(spacing: StatusBarChrome.clusterSpacing) {
                if model.controls.showsSelectionSummary {
                    SelectionSummaryReadout(
                        state: selectionSummary,
                        scopeNote: selectionSummaryScopeNote,
                        isPopoverPresented: $showSelectionSummaryPopover
                    )
                }
                if model.controls.showsReadout {
                    readoutMessage
                }
                executionReport
                if model.controls.showsReadout, isRefreshingSchema, !executionOwnsSpinner {
                    DelayedProgressIndicator(isActive: true)
                        .accessibilityLabel(String(localized: "Refreshing"))
                }
            }
        }
    }

    @ViewBuilder
    private var readoutSentence: some View {
        if model.controls.showsLoadingMore {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ResultStatusReadoutView(readout: model.readout, showsLoadingIndicator: !executionOwnsSpinner)
        }

        if model.controls.showsCountInProgress {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Counting rows"))
        }
    }

    // Never truncated: `ReadoutZoneLayout` counts their width, so the bar drops a tier first.
    @ViewBuilder
    private var readoutActions: some View {
        if model.controls.showsExactCountAction {
            Button(
                String(localized: "Count Exactly"),
                action: paginationCallbacks.onRequestExactCount
            )
            .accessoryBarActionStyle()
            .controlSize(.small)
            .fixedSize()
            .help(String(localized: "Replace the estimate with an exact row count."))
            .accessibilityIdentifier("result-status-count-exactly")
        }

        if model.controls.showsFetchAll, let onFetchAll {
            Button(String(localized: "Fetch All"), action: onFetchAll)
                .accessoryBarActionStyle()
                .controlSize(.small)
                .fixedSize()
                .help(String(localized: "Load the rows the row cap left behind."))
                .accessibilityIdentifier("result-status-fetch-all")
        }
    }

    @ViewBuilder
    private var readoutMessage: some View {
        if let statusMessage = model.statusMessage {
            // Truncates first, and `ReadoutZoneLayout` leaves it out of the ideal width, so no message changes the tier.
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }

    @ViewBuilder
    private var executionReport: some View {
        let slot = ExecutionSlot(
            isOffered: model.controls.showsExecution,
            isRevealed: revealedExecutionTabId == execution.tabId,
            lastTiming: execution.lastTiming
        )
        if let report = slot.report {
            ExecutionIndicatorView(
                report: report,
                isExecuting: execution.isExecuting,
                canStop: execution.canStop,
                onCancel: execution.onCancel
            )
        }
    }

    // The execution indicator spins from the moment it is revealed, so nothing else on the bar does then.
    private var executionOwnsSpinner: Bool {
        model.controls.showsExecution && execution.isExecuting
    }

    private var selectionSummaryScopeNote: String? {
        model.selectionSummaryCoversLoadedRowsOnly ? String(localized: "Covers the loaded rows only.") : nil
    }

    // No `idealWidth`: `ReadoutZoneLayout` reports the zone's ideal, and a frame naming one would replace it.
    private func readoutZone(_ content: some View) -> some View {
        content.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private static let readoutSpacing: CGFloat = 6

    @ViewBuilder
    private func controlCluster(_ presentation: ResultStatusPresentation) -> some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if model.controls.showsColumns {
                columnsButton(presentation)
            }
            if model.controls.showsHighlightRules {
                highlightButton
            }
            if model.controls.showsAutoRefresh, presentation.showsAutoRefresh {
                autoRefreshMenu(presentation)
            }
            if model.controls.showsFilters {
                filtersToggle(presentation)
            }
            if model.controls.showsPagination {
                paginationControls(presentation)
            }
        }
        .fixedSize()
    }

    // The tab id is passed, not applied as `.id()`, which rebuilt the cluster on every switch.
    private func paginationControls(_ presentation: ResultStatusPresentation) -> some View {
        PaginationControlsView(
            pagination: snapshot.pagination,
            loadedRowCount: snapshot.rowCount,
            tabId: snapshot.tabId,
            showsPageNavigation: model.controls.showsPageNavigation,
            showsEdgePageButtons: presentation.showsEdgePageButtons,
            pageSizeIsInline: presentation.pageSizeIsInline,
            maximumPageSize: snapshot.paginationCapability.maximumRows,
            onFirst: paginationCallbacks.onFirst,
            onPrevious: paginationCallbacks.onPrevious,
            onNext: paginationCallbacks.onNext,
            onLast: paginationCallbacks.onLast,
            onPageSizeChange: paginationCallbacks.onPageSizeChange,
            onShowAll: paginationCallbacks.onShowAll,
            onGoToPage: paginationCallbacks.onGoToPage
        )
    }

    private func columnsButton(_ presentation: ResultStatusPresentation) -> some View {
        Button {
            showColumnPopover.toggle()
        } label: {
            Label {
                Text("Columns")
            } icon: {
                Image(systemName: hasHiddenColumns ? "eye.slash" : "eye")
                    .statusBarControlIcon(besideTitle: presentation.showsControlTitles)
            }
        }
        .statusBarLabelStyle(showsTitle: presentation.showsControlTitles)
        .controlSize(.small)
        // Dimmed, not removed, while columns load, so nothing beside it shifts.
        .disabled(columnState.columns.isEmpty)
        .help(String(localized: "Choose which columns the grid shows"))
        .accessibilityLabel(String(localized: "Columns"))
        .accessibilityValue(columnsAccessibilityValue)
        .accessibilityIdentifier("result-status-columns")
        .popover(isPresented: $showColumnPopover, arrowEdge: .top) {
            ColumnVisibilityPopover(
                columns: columnState.visibilityColumns,
                hiddenColumns: columnState.hidden,
                onToggleColumn: columnState.onToggle,
                onShowAll: columnState.onShowAll,
                onHideAll: columnState.onHideAll,
                onReset: columnState.onReset,
                onJumpToColumn: columnState.onJumpToColumn.map { jump in
                    { query in
                        showColumnPopover = false
                        jump(query)
                    }
                }
            )
        }
    }

    private var highlightButton: some View {
        Button {
            showHighlightPopover.toggle()
        } label: {
            Label {
                Text("Highlight Rules")
            } icon: {
                Image(systemName: "highlighter")
                    .statusBarControlIcon(besideTitle: false)
            }
        }
        // A glyph at every tier: its title would cost the regular tier at the default 1200pt window.
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .disabled(highlightState.columns.isEmpty)
        .help(String(localized: "Highlight Rules"))
        .accessibilityLabel(String(localized: "Highlight Rules"))
        .accessibilityValue(highlightAccessibilityValue)
        .accessibilityIdentifier("result-status-highlight")
        .popover(isPresented: $showHighlightPopover, arrowEdge: .top) {
            HighlightRulesPopover(
                columns: highlightState.columns,
                rules: highlightState.rules,
                isPersisted: highlightState.isPersisted,
                onChange: highlightState.onChange
            )
        }
    }

    private var highlightPresentation: HighlightPresentationRequest {
        HighlightPresentationRequest(tabId: snapshot.tabId, count: highlightState.presentationRequest)
    }

    private var highlightAccessibilityValue: String {
        let count = highlightState.activeRuleCount
        guard count > 0 else { return String(localized: "No highlight rules") }
        return String(format: String(localized: "%d rules"), count)
    }

    // A Menu around an inline Picker: a pop-up button always spells out its choice, so it could not go to a glyph.
    private func autoRefreshMenu(_ presentation: ResultStatusPresentation) -> some View {
        Menu {
            Picker(
                String(localized: "Auto Refresh"),
                selection: Binding(get: { autoRefresh.interval }, set: { autoRefresh.onChange($0) })
            ) {
                ForEach(TableAutoRefreshInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label {
                Text(autoRefresh.interval.shortTitle)
            } icon: {
                (Self.autoRefreshSymbol(isOn: autoRefresh.interval.isOn).map(Image.init(nsImage:))
                    ?? Image(systemName: Self.autoRefreshSymbolName))
                    .statusBarControlIcon(besideTitle: presentation.showsControlTitles)
            }
        }
        .menuStyle(.button)
        .menuIndicator(presentation.showsControlTitles ? .visible : .hidden)
        .statusBarLabelStyle(showsTitle: presentation.showsControlTitles)
        .controlSize(.small)
        .fixedSize()
        .help(autoRefresh.help)
        .accessibilityLabel(String(localized: "Auto Refresh"))
        .accessibilityValue(autoRefresh.interval.title)
        .accessibilityIdentifier("result-status-auto-refresh")
    }

    static let autoRefreshSymbolName = "clock.arrow.circlepath"

    // A menu draws a SwiftUI symbol as a template and drops its tint, so the on state is an accent palette image.
    static func autoRefreshSymbol(isOn: Bool) -> NSImage? {
        let size = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize(for: .small), weight: .regular)
        let configuration = isOn ? size.applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) : size
        guard let image = NSImage(systemSymbolName: autoRefreshSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = !isOn
        return image
    }

    private func filtersToggle(_ presentation: ResultStatusPresentation) -> some View {
        Toggle(isOn: Binding(get: { filterState.isVisible }, set: { _ in onToggleFilters() })) {
            Label {
                Text("Filters")
            } icon: {
                Image(systemName: filterState.isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .statusBarControlIcon(besideTitle: presentation.showsControlTitles)
            }
        }
        .statusBarLabelStyle(showsTitle: presentation.showsControlTitles)
        .toggleStyle(.button)
        .controlSize(.small)
        .help(keyboard.value.shortcutHint(String(localized: "Filters"), for: .toggleFilters))
        .accessibilityLabel(String(localized: "Filters"))
        .accessibilityValue(filtersAccessibilityValue)
        .accessibilityAddTraits(filterState.isVisible ? .isSelected : [])
        .accessibilityIdentifier("result-status-filters")
    }

    private var hasHiddenColumns: Bool {
        !columnState.hidden.isEmpty
    }

    // A value, not part of the name, so VoiceOver reads one control name however many columns are hidden.
    private var columnsAccessibilityValue: String {
        guard hasHiddenColumns else { return String(localized: "All columns visible") }
        let total = columnState.visibilityColumns.count
        return String(format: String(localized: "%d of %d columns visible"), total - columnState.hidden.count, total)
    }

    // Explicit singular and plural keys: `String(localized:)` does not process inflection.
    private var filtersAccessibilityValue: String {
        guard let applied = filterState.applied else { return String(localized: "No filters applied") }
        guard applied.filters.count > 1 else { return String(localized: "1 filter applied") }
        return String(format: String(localized: "%d filters applied"), applied.filters.count)
    }
}

// Reports the ideal width `ViewThatFits` picks a tier by: the sentence and report count as one constant, the actions on top.
private struct ReadoutZoneLayout: Layout {
    let spacing: CGFloat
    let sentenceIdealWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = slotSizes(width: proposal.width, height: proposal.height, subviews: subviews)
        let height = sizes.map(\.height).max() ?? 0
        guard proposal.width != nil else {
            let actions = subviews.count == 3 ? sizes[1].width : 0
            return CGSize(width: sentenceIdealWidth + (actions > 0 ? spacing + actions : 0), height: height)
        }
        return CGSize(width: span(of: sizes.map(\.width)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = slotSizes(width: bounds.width, height: bounds.height, subviews: subviews)
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) where size.width > 0 {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: size.width, height: bounds.height)
            )
            x += size.width + spacing
        }
    }

    private func slotSizes(width: CGFloat?, height: CGFloat?, subviews: Subviews) -> [CGSize] {
        guard let width, subviews.count == 3 else {
            return subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: height)) }
        }
        let sentence = subviews[0], actions = subviews[1], report = subviews[2]
        let actionsSize = actions.sizeThatFits(ProposedViewSize(width: nil, height: height))
        let sentenceIdeal = sentence.sizeThatFits(ProposedViewSize(width: nil, height: height)).width
        let reportIdeal = report.sizeThatFits(ProposedViewSize(width: nil, height: height)).width
        let reportFloor = report.sizeThatFits(ProposedViewSize(width: 0, height: height)).width
        let gaps = span(of: [sentenceIdeal, actionsSize.width, reportIdeal]) - sentenceIdeal - actionsSize.width - reportIdeal

        let sentenceWidth = min(sentenceIdeal, max(0, width - gaps - actionsSize.width - reportFloor))
        let reportWidth = max(reportFloor, width - gaps - actionsSize.width - sentenceWidth)
        return [
            sentence.sizeThatFits(ProposedViewSize(width: sentenceWidth, height: height)),
            actionsSize,
            report.sizeThatFits(ProposedViewSize(width: reportWidth, height: height)),
        ]
    }

    private func span(of widths: [CGFloat]) -> CGFloat {
        let drawn = widths.filter { $0 > 0 }
        return drawn.reduce(0, +) + spacing * CGFloat(max(0, drawn.count - 1))
    }
}

private extension View {
    // `titleAndIcon` and `iconOnly` are different types, so a ternary cannot choose between them.
    @ViewBuilder
    func statusBarLabelStyle(showsTitle: Bool) -> some View {
        if showsTitle {
            labelStyle(.titleAndIcon)
        } else {
            labelStyle(.iconOnly)
        }
    }
}
