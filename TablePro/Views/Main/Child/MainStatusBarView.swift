//
//  MainStatusBarView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 24/12/25.
//

import SwiftUI

struct PaginationCallbacks {
    let onFirst: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onLast: () -> Void
    let onPageSizeChange: (Int) -> Void
    let onShowAll: () -> Void
    let onGoToPage: (Int) -> Void
}

struct StatusBarColumnState {
    let hidden: Set<String>
    let all: [String]
    let onToggle: (String) -> Void
    let onShowAll: () -> Void
    let onHideAll: ([String]) -> Void
}

struct StatusBarStructureState {
    let footer: StructureFooterState
    let onAdd: () -> Void
    let onRemove: () -> Void
}

struct MainStatusBarView: View {
    let snapshot: StatusBarSnapshot
    let filterState: TabFilterState
    let selectedRowIndices: Set<Int>
    @Binding var viewMode: ResultsViewMode
    let paginationCallbacks: PaginationCallbacks
    let columnState: StatusBarColumnState
    let structureState: StatusBarStructureState
    let onToggleFilters: () -> Void
    let onFetchAll: (() -> Void)?
    let onAddRow: (() -> Void)?

    @State private var showColumnPopover = false

    private var isStructureMode: Bool { viewMode == .structure }
    private var showsDataChrome: Bool { !isStructureMode }

    static func showsAddRow(viewMode: ResultsViewMode, canAddRow: Bool) -> Bool {
        viewMode == .data && canAddRow
    }

    private var showsAddButton: Bool {
        Self.showsAddRow(viewMode: viewMode, canAddRow: onAddRow != nil)
    }

    private var showsFiltersToggle: Bool {
        snapshot.tabType == .table && snapshot.hasTableName
    }

    private var showsActionButtons: Bool {
        showsDataChrome && (showsAddButton || snapshot.hasColumns || showsFiltersToggle)
    }

    private var showsPagination: Bool {
        snapshot.tabType == .table && snapshot.hasTableName && snapshot.showsPaginationControls
    }

    private var showsTruncation: Bool {
        snapshot.tabType == .query && snapshot.pagination.hasMoreRows && !snapshot.pagination.isLoadingMore
    }

    private func hasStatusText(_ status: String?) -> Bool {
        snapshot.pagination.isLoadingMore
            || status != nil
            || showsTruncation
            || snapshot.statusMessage != nil
    }

    private func hasPrimaryStatus(_ status: String?) -> Bool {
        snapshot.pagination.isLoadingMore || status != nil
    }

    private func showsDataNavigation(_ status: String?) -> Bool {
        showsDataChrome && (hasStatusText(status) || showsPagination)
    }

    var body: some View {
        HStack(spacing: 8) {
            viewModePicker
            Spacer(minLength: 8)
            trailingControls
        }
        .padding(.leading, 8)
        .padding(.trailing, 20)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: snapshot.tabId) { _, _ in
            showColumnPopover = false
        }
    }

    @ViewBuilder
    private var viewModePicker: some View {
        if snapshot.tabId != nil {
            if snapshot.tabType == .table, snapshot.hasTableName {
                Picker(String(localized: "View Mode"), selection: $viewMode) {
                    Label("Data", systemImage: "tablecells").tag(ResultsViewMode.data)
                    Label("Structure", systemImage: "list.bullet.rectangle").tag(ResultsViewMode.structure)
                    Label("JSON", systemImage: "curlybraces").tag(ResultsViewMode.json)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                .controlSize(.small)
            } else if snapshot.hasColumns {
                Picker(String(localized: "View Mode"), selection: $viewMode) {
                    Label("Data", systemImage: "tablecells").tag(ResultsViewMode.data)
                    Label("JSON", systemImage: "curlybraces").tag(ResultsViewMode.json)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        let status = snapshot.statusText(selectedCount: selectedRowIndices.count)
        HStack(spacing: 8) {
            if isStructureMode {
                if structureState.footer.isActive {
                    structureFooterControls(state: structureState.footer)
                }
            } else {
                actionButtons
                if showsActionButtons, showsDataNavigation(status) {
                    Divider().frame(height: 16)
                }
                dataNavigationGroup(status: status)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if showsAddButton, let onAddRow {
            Button {
                onAddRow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add")
                }
            }
            .controlSize(.small)
            .help(addRowHelp)
            .accessibilityLabel(String(localized: "Add Row"))
        }

        if snapshot.hasColumns {
            columnsButton
        }

        if showsFiltersToggle {
            filtersToggle
        }
    }

    private var columnsButton: some View {
        Button {
            showColumnPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: !columnState.hidden.isEmpty ? "eye.slash.circle.fill" : "eye.circle")
                Text("Columns")
                if !columnState.hidden.isEmpty {
                    let visible = columnState.all.count - columnState.hidden.count
                    Text("(\(visible)/\(columnState.all.count))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
        .accessibilityLabel(columnsAccessibilityLabel)
        .popover(isPresented: $showColumnPopover, arrowEdge: .top) {
            ColumnVisibilityPopover(
                columns: columnState.all,
                hiddenColumns: columnState.hidden,
                onToggleColumn: columnState.onToggle,
                onShowAll: columnState.onShowAll,
                onHideAll: columnState.onHideAll
            )
        }
    }

    private var filtersToggle: some View {
        Toggle(isOn: Binding(
            get: { filterState.isVisible },
            set: { _ in onToggleFilters() }
        )) {
            HStack(spacing: 4) {
                Image(systemName: filterState.hasAppliedFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                Text("Filters")
                if filterState.hasAppliedFilters {
                    Text("(\(filterState.appliedFilters.count))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(filterToggleHelp)
        .accessibilityLabel(String(localized: "Filters"))
        .accessibilityAddTraits(filterState.isVisible ? .isSelected : [])
    }

    @ViewBuilder
    private func dataNavigationGroup(status: String?) -> some View {
        if showsDataNavigation(status) {
            HStack(spacing: 4) {
                statusCluster(status: status)
                if showsPagination {
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
                }
            }
        }
    }

    private var statusSeparator: some View {
        Text("·")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func statusCluster(status: String?) -> some View {
        if snapshot.pagination.isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Loading more rows"))
        } else if let status {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        if showsTruncation {
            if hasPrimaryStatus(status) {
                statusSeparator
            }
            Text("truncated")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                onFetchAll?()
            } label: {
                Text("Fetch All")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }

        if let statusMessage = snapshot.statusMessage {
            if hasPrimaryStatus(status) || showsTruncation {
                statusSeparator
            }
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func structureFooterControls(state: StructureFooterState) -> some View {
        ControlGroup {
            Button {
                structureState.onAdd()
            } label: {
                Label(state.addLabel, systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .help(state.addLabel)
            .accessibilityLabel(state.addLabel)
            .disabled(!state.canAdd)

            Button {
                structureState.onRemove()
            } label: {
                Label(state.removeLabel, systemImage: "minus")
                    .labelStyle(.iconOnly)
            }
            .help(state.removeLabel)
            .accessibilityLabel(state.removeLabel)
            .disabled(!state.canRemove)
        }
        .controlGroupStyle(.navigation)
        .controlSize(.small)
        .fixedSize()
    }

    private var filterToggleHelp: String {
        helpText(String(localized: "Toggle Filters"), shortcut: .toggleFilters)
    }

    private var addRowHelp: String {
        helpText(String(localized: "Add Row"), shortcut: .addRow)
    }

    private func helpText(_ label: String, shortcut action: ShortcutAction) -> String {
        AppSettingsManager.shared.keyboard.shortcutHint(label, for: action)
    }

    private var columnsAccessibilityLabel: String {
        guard !columnState.hidden.isEmpty else {
            return String(localized: "Columns")
        }
        let visible = columnState.all.count - columnState.hidden.count
        return String(format: String(localized: "%d of %d columns visible"), visible, columnState.all.count)
    }
}
