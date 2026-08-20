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
/// Nothing here mutates the document. Adding a row and adding or dropping a column are commands
/// about the data, so they live with the data: the toolbar and the structure list's own footer.
struct ResultStatusBar: View {
    let model: ResultStatusModel
    let snapshot: StatusBarSnapshot
    let filterState: TabFilterState
    let columnState: StatusBarColumnState
    let paginationCallbacks: PaginationCallbacks
    let onToggleFilters: () -> Void
    let onFetchAll: (() -> Void)?

    @State private var showColumnPopover = false

    var body: some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            readoutCluster
            Spacer(minLength: StatusBarChrome.clusterSpacing)
            controlCluster
        }
        .statusBarChrome()
        .onChange(of: snapshot.tabId) { _, _ in
            showColumnPopover = false
        }
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
        }
        .fixedSize()
    }

    /// Keyed by tab, because its jump and rows-per-page popovers hold `@State`. Sharing one identity
    /// across a tab switch meant a page number typed for one tab was submitted against the next.
    private var paginationControls: some View {
        PaginationControlsView(
            pagination: snapshot.pagination,
            loadedRowCount: snapshot.rowCount,
            onFirst: paginationCallbacks.onFirst,
            onPrevious: paginationCallbacks.onPrevious,
            onNext: paginationCallbacks.onNext,
            onLast: paginationCallbacks.onLast,
            onPageSizeChange: paginationCallbacks.onPageSizeChange,
            onShowAll: paginationCallbacks.onShowAll,
            onGoToPage: paginationCallbacks.onGoToPage
        )
        .id(snapshot.tabId)
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
        .help(String(localized: "Choose which columns the grid shows"))
        .accessibilityLabel(String(localized: "Columns"))
        .accessibilityValue(columnsAccessibilityValue)
        .accessibilityIdentifier("result-status-columns")
        .popover(isPresented: $showColumnPopover, arrowEdge: .top) {
            ColumnVisibilityPopover(
                columns: columnState.all,
                hiddenColumns: columnState.hidden,
                onToggleColumn: columnState.onToggle,
                onShowAll: columnState.onShowAll,
                onHideAll: columnState.onHideAll,
                onReset: columnState.onReset
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
        let visible = columnState.all.count - columnState.hidden.count
        return String(format: String(localized: "%d of %d columns visible"), visible, columnState.all.count)
    }

    private var filtersAccessibilityValue: String {
        guard filterState.hasAppliedFilters else { return String(localized: "No filters applied") }
        return String(format: String(localized: "%d filters applied"), filterState.appliedFilters.count)
    }
}
