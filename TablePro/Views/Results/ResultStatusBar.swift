//
//  ResultStatusBar.swift
//  TablePro
//

import SwiftUI

/// The window's bottom bar: what the result is, and the controls that change what of it you see.
///
/// Two zones, never three. Centring a variable-width sentence between two variable-width clusters
/// only holds while the clusters happen to match, which is why the row count sat visibly left of
/// centre. Anchoring the readout to the leading edge and the controls to the trailing edge also
/// keeps the controls still when a mode change removes one of them.
///
/// The view switcher leads the bar, the way TablePlus and Postico place theirs. It was briefly a
/// strip of its own above the result, which cost a band of height in every mode and left the
/// structure editor with two segmented rows stacked, the child louder than the parent.
///
/// Adding a row still belongs to the toolbar: it changes the document. The structure editor's
/// add and remove pair is this bar's trailing cluster while the structure editor is the content,
/// because a second bar underneath it would be the stacking problem again, one bar lower.
///
/// The bar gives up chrome rather than overflowing its pane. Its clusters used to be pinned at full
/// width, which made the bar's own minimum wider than the pane and clipped the data grid along with
/// it; see `StatusBarTier`. `ViewThatFits` picks the widest tier whose ideal width fits, and the
/// narrowest tier holds its shape down to 280pt, measured, against a pane whose own floor is 400pt.
/// Two rules keep that true. No candidate row carries `.fixedSize()`: the clusters carry their own,
/// and the readout's constant `idealWidth` is what makes a candidate's ideal width equal its floor,
/// so the mounted row still grows to fill the pane and anchor the controls to the trailing edge. And
/// no tier drops a control that opens a popover: one anchored to a button that has left the view
/// tree cannot present, so giving up the Highlight Rules button would have made
/// `View > Highlight Rules…` do nothing. See `StatusBarTier` for what a tier may give up.
struct ResultStatusBar: View {
    let model: ResultStatusModel
    let snapshot: StatusBarSnapshot
    let filterState: TabFilterState
    let columnState: StatusBarColumnState
    let highlightState: StatusBarHighlightState
    let paginationCallbacks: PaginationCallbacks
    let structureFooter: StructureFooterCapability
    let execution: ExecutionReadout
    /// The object tree's own reload, reported where every other piece of background activity in
    /// this window is. It had no surface at all between the centred toolbar item going and this.
    let isRefreshingSchema: Bool
    @Binding var viewMode: ResultsViewMode
    let onToggleFilters: () -> Void
    let onFetchAll: (() -> Void)?
    let onStructureAdd: () -> Void
    let onStructureRemove: () -> Void

    @State private var showColumnPopover = false
    @State private var showHighlightPopover = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.regular)
            row(.compact)
            row(.narrow)
        }
        .statusBarChrome()
        .onChange(of: snapshot.tabId) { _, _ in
            showColumnPopover = false
            showHighlightPopover = false
        }
        .onChange(of: showHighlightPopover) { _, isShown in
            guard !isShown else { return }
            highlightState.onDismiss()
        }
        .onChange(of: highlightPresentation) { previous, current in
            guard previous.tabId == current.tabId, model.controls.showsHighlightRules else { return }
            showHighlightPopover = true
        }
    }

    /// One row of the bar, drawn the way its tier says. `ViewThatFits` measures each of these and
    /// mounts the first that fits, so this is both the measurement and the result.
    @ViewBuilder
    private func row(_ tier: StatusBarTier) -> some View {
        let presentation = ResultStatusPresentation(tier: tier)
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if model.controls.showsModeSwitcher {
                modeSwitcher(presentation)
            }
            if model.controls.showsReadout {
                readoutCluster
                    .frame(
                        minWidth: 0,
                        idealWidth: StatusBarLayoutMetrics.readoutIdealWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            } else {
                Spacer(minLength: 0)
            }
            controlCluster(presentation)
        }
    }

    /// Segmented while the modes fit, and a pull-down naming the current one once they do not. The
    /// pull-down is capped, because it takes the width of its widest item and a long locale would
    /// otherwise decide the narrow tier's floor.
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
                .pickerStyle(.segmented)
                .fixedSize()
        } else {
            picker
                .pickerStyle(.menu)
                .frame(maxWidth: StatusBarLayoutMetrics.modeMenuMaximumWidth)
        }
    }

    // MARK: - Readout

    /// The zone that absorbs the bar's slack, which is why `row` gives it the flexible frame and the
    /// clusters on either side keep their intrinsic widths.
    private var readoutCluster: some View {
        HStack(spacing: 6) {
            if model.controls.showsLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ResultStatusReadoutView(readout: model.readout)
            }

            if model.controls.showsCountInProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Counting rows"))
            }

            if model.controls.showsExactCountAction {
                Button(
                    String(localized: "Count Exactly"),
                    action: paginationCallbacks.onRequestExactCount
                )
                .buttonStyle(.accessoryBarAction)
                .help(String(localized: "Replace the estimate with an exact row count."))
                .accessibilityIdentifier("result-status-count-exactly")
            }

            if model.controls.showsFetchAll, let onFetchAll {
                Button(String(localized: "Fetch All"), action: onFetchAll)
                    .buttonStyle(.accessoryBarAction)
                    .help(String(localized: "Load the rows the row cap left behind."))
                    .accessibilityIdentifier("result-status-fetch-all")
            }

            if let statusMessage = model.statusMessage {
                separator
                /// Yields its width before the sentence beside it does, so a wordy driver message
                /// truncates instead of squeezing out the row count. Which tier the bar draws is not
                /// its business: the enclosing frame reports a constant ideal width so no message
                /// length can change that choice.
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }

            executionReadout
        }
    }

    /// Whether a query is running and how long the last one took, beside the rows it produced. It
    /// used to be a hosted SwiftUI view in the centre of the toolbar, where AppKit dropped it whole
    /// before any command as soon as the window narrowed.
    @ViewBuilder
    private var executionReadout: some View {
        if execution.isActive {
            separator
            ExecutionIndicatorView(
                isExecuting: execution.isExecuting,
                lastTiming: execution.lastTiming,
                onCancel: execution.onCancel
            )
        }
        if isRefreshingSchema {
            DelayedProgressIndicator(isActive: true)
                .accessibilityLabel(String(localized: "Refreshing"))
        }
    }

    /// Punctuation, so VoiceOver must not read it as an element of its own.
    private var separator: some View {
        Text(verbatim: "·")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    // MARK: - Controls

    @ViewBuilder
    private func controlCluster(_ presentation: ResultStatusPresentation) -> some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if model.controls.showsColumns {
                columnsButton(presentation)
            }
            if model.controls.showsHighlightRules {
                highlightButton
            }
            if model.controls.showsFilters {
                filtersToggle(presentation)
            }
            if model.controls.showsPagination {
                paginationControls(presentation)
            }
            if model.controls.showsStructureActions {
                AddRemoveControlGroup(
                    addLabel: structureFooter.addLabel,
                    removeLabel: structureFooter.removeLabel,
                    canAdd: structureFooter.canAdd,
                    canRemove: structureFooter.canRemove,
                    addHelp: structureFooter.unavailableReason,
                    removeHelp: structureFooter.unavailableReason,
                    addIdentifier: "structure-footer-add",
                    removeIdentifier: "structure-footer-remove",
                    onAdd: onStructureAdd,
                    onRemove: onStructureRemove
                )
            }
        }
        .fixedSize()
    }

    /// The tab identity is passed in rather than applied as `.id()`. Keying the view by tab did stop
    /// a page number typed for one tab being submitted against the next, but it also tore the whole
    /// cluster down and rebuilt it on every switch, which is a second source of the churn this bar
    /// exists to avoid. The view resets the same `@State` on the same signal instead.
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
            }
        }
        .statusBarLabelStyle(showsTitle: presentation.showsControlTitles)
        .controlSize(.small)
        /// Present but inert until the result names its columns, so a reload dims the button rather
        /// than removing it and shifting everything beside it.
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
            }
        }
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

    private func filtersToggle(_ presentation: ResultStatusPresentation) -> some View {
        Toggle(isOn: Binding(get: { filterState.isVisible }, set: { _ in onToggleFilters() })) {
            Label {
                Text("Filters")
            } icon: {
                Image(systemName: filterState.hasAppliedFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
        }
        .statusBarLabelStyle(showsTitle: presentation.showsControlTitles)
        .toggleStyle(.button)
        .controlSize(.small)
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Filters"), for: .toggleFilters))
        .accessibilityLabel(String(localized: "Filters"))
        .accessibilityValue(filtersAccessibilityValue)
        .accessibilityAddTraits(filterState.isVisible ? .isSelected : [])
        .accessibilityIdentifier("result-status-filters")
    }

    private var hasHiddenColumns: Bool {
        !columnState.hidden.isEmpty
    }

    /// The count is a value, not part of the name. Folding it into the label made VoiceOver read a
    /// different control name depending on how many columns happened to be hidden.
    private var columnsAccessibilityValue: String {
        guard hasHiddenColumns else { return String(localized: "All columns visible") }
        let total = columnState.visibilityColumns.count
        return String(format: String(localized: "%d of %d columns visible"), total - columnState.hidden.count, total)
    }

    private var filtersAccessibilityValue: String {
        guard filterState.hasAppliedFilters else { return String(localized: "No filters applied") }
        return String(format: String(localized: "%d filters applied"), filterState.appliedFilters.count)
    }
}

private extension View {
    /// `titleAndIcon` and `iconOnly` are different types, so a tier choosing between them cannot do
    /// it with a ternary. Branching here keeps each control's modifier chain written once, and keeps
    /// the system's own label metrics rather than a hand-rolled stack's.
    @ViewBuilder
    func statusBarLabelStyle(showsTitle: Bool) -> some View {
        if showsTitle {
            labelStyle(.titleAndIcon)
        } else {
            labelStyle(.iconOnly)
        }
    }
}
