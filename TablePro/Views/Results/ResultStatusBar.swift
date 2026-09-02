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
struct ResultStatusBar: View {
    let model: ResultStatusModel
    let snapshot: StatusBarSnapshot
    let filterState: TabFilterState
    let columnState: StatusBarColumnState
    let paginationCallbacks: PaginationCallbacks
    let structureFooter: StructureFooterCapability
    @Binding var viewMode: ResultsViewMode
    let onToggleFilters: () -> Void
    let onFetchAll: (() -> Void)?
    let onStructureAdd: () -> Void
    let onStructureRemove: () -> Void

    @State private var showColumnPopover = false

    var body: some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if model.controls.showsModeSwitcher {
                modeSwitcher
            }
            readoutCluster
            Spacer(minLength: StatusBarChrome.clusterSpacing)
            controlCluster
        }
        .statusBarChrome()
        .onChange(of: snapshot.tabId) { _, _ in
            showColumnPopover = false
        }
    }

    private var modeSwitcher: some View {
        Picker(String(localized: "View Mode"), selection: $viewMode) {
            ForEach(snapshot.availableModes, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("results-view-mode-picker")
    }

    // MARK: - Readout

    @ViewBuilder
    private var readoutCluster: some View {
        if model.controls.showsReadout {
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
                    /// The one part of the bar allowed to shrink. Without that the readout keeps its
                    /// full intrinsic width and a wordy driver message pushes the pagination cluster
                    /// past the trailing edge, out of reach.
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
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
    private var controlCluster: some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if model.controls.showsColumns {
                columnsButton
            }
            if model.controls.showsFilters {
                filtersToggle
            }
            if model.controls.showsPagination {
                paginationControls
            }
            if model.controls.showsStructureActions {
                AddRemoveControlGroup(
                    addLabel: structureFooter.addLabel,
                    removeLabel: structureFooter.removeLabel,
                    canAdd: structureFooter.canAdd,
                    canRemove: structureFooter.canRemove,
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
    private var paginationControls: some View {
        PaginationControlsView(
            pagination: snapshot.pagination,
            loadedRowCount: snapshot.rowCount,
            tabId: snapshot.tabId,
            onFirst: paginationCallbacks.onFirst,
            onPrevious: paginationCallbacks.onPrevious,
            onNext: paginationCallbacks.onNext,
            onLast: paginationCallbacks.onLast,
            onPageSizeChange: paginationCallbacks.onPageSizeChange,
            onShowAll: paginationCallbacks.onShowAll,
            onGoToPage: paginationCallbacks.onGoToPage
        )
    }

    private var columnsButton: some View {
        Button {
            showColumnPopover.toggle()
        } label: {
            Label {
                Text("Columns")
            } icon: {
                Image(systemName: hasHiddenColumns ? "eye.slash" : "eye")
            }
        }
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

    private var filtersToggle: some View {
        Toggle(isOn: Binding(get: { filterState.isVisible }, set: { _ in onToggleFilters() })) {
            Label {
                Text("Filters")
            } icon: {
                Image(systemName: filterState.hasAppliedFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
        }
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
