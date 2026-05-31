//
//  MainStatusBarView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 24/12/25.
//

import SwiftUI

struct StatusBarSnapshot: Equatable {
    let tabId: UUID?
    let tabType: TabType?
    let hasRows: Bool
    let hasColumns: Bool
    let rowCount: Int
    let hasTableName: Bool
    let pagination: PaginationState
    let statusMessage: String?

    init(tab: QueryTab?, tableRows: TableRows?) {
        self.tabId = tab?.id
        self.tabType = tab?.tabType
        self.hasRows = !(tableRows?.rows.isEmpty ?? true)
        self.hasColumns = !(tableRows?.columns.isEmpty ?? true)
        self.rowCount = tableRows?.rows.count ?? 0
        self.hasTableName = tab?.tableContext.tableName != nil
        self.pagination = tab?.pagination ?? PaginationState()
        self.statusMessage = tab?.execution.statusMessage
    }
}

struct MainStatusBarView: View {
    let snapshot: StatusBarSnapshot
    let filterState: TabFilterState
    let hiddenColumns: Set<String>
    let allColumns: [String]
    let selectedRowIndices: Set<Int>
    @Binding var viewMode: ResultsViewMode

    @State private var showColumnPopover = false

    // Pagination callbacks
    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onPageSizeChange: (Int) -> Void
    let onShowAll: () -> Void
    let onGoToPage: (Int) -> Void

    // Column visibility callbacks
    let onToggleColumn: (String) -> Void
    let onShowAllColumns: () -> Void
    let onHideAllColumns: ([String]) -> Void

    // Filter visibility callback
    let onToggleFilters: () -> Void

    // Truncated result callback
    var onFetchAll: (() -> Void)?

    // Structure-mode footer accessory (Add/Remove buttons)
    let structureFooterState: StructureFooterState?
    let onStructureAdd: (() -> Void)?
    let onStructureRemove: (() -> Void)?

    private var hasHiddenColumns: Bool { !hiddenColumns.isEmpty }
    private var hiddenCount: Int { hiddenColumns.count }

    private var isStructureMode: Bool { viewMode == .structure }
    private var showsDataChrome: Bool { !isStructureMode }

    private var filterToggleHelp: String {
        let label = String(localized: "Toggle Filters")
        guard let combo = AppSettingsManager.shared.keyboard.shortcut(for: .toggleFilters),
              !combo.isCleared else {
            return label
        }
        return "\(label) (\(combo.displayString))"
    }

    var body: some View {
        HStack {
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

            Spacer()

            if showsDataChrome, snapshot.hasRows {
                HStack(spacing: 4) {
                    if snapshot.pagination.isLoadingMore {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(rowInfoText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if snapshot.tabType == .query && snapshot.pagination.hasMoreRows && !snapshot.pagination.isLoadingMore {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
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
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if isStructureMode, let state = structureFooterState, state.isActive {
                    structureFooterControls(state: state)
                }

                if showsDataChrome {
                    if snapshot.hasColumns {
                        Button {
                            showColumnPopover.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: hasHiddenColumns
                                        ? "eye.slash.circle.fill"
                                        : "eye.circle")
                                Text("Columns")
                                if hasHiddenColumns {
                                    let visible = allColumns.count - hiddenCount
                                    Text("(\(visible)/\(allColumns.count))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .controlSize(.small)
                        .popover(isPresented: $showColumnPopover) {
                            ColumnVisibilityPopover(
                                columns: allColumns,
                                hiddenColumns: hiddenColumns,
                                onToggleColumn: onToggleColumn,
                                onShowAll: onShowAllColumns,
                                onHideAll: onHideAllColumns
                            )
                        }
                    }

                    if snapshot.tabType == .table, snapshot.hasTableName {
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
                    }

                    if snapshot.tabType == .table, snapshot.hasTableName, showsPaginationControls {
                        PaginationControlsView(
                            pagination: snapshot.pagination,
                            loadedRowCount: snapshot.rowCount,
                            onFirst: onFirstPage,
                            onPrevious: onPreviousPage,
                            onNext: onNextPage,
                            onLast: onLastPage,
                            onPageSizeChange: onPageSizeChange,
                            onShowAll: onShowAll,
                            onGoToPage: onGoToPage
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: snapshot.tabId) { _, _ in
            showColumnPopover = false
        }
    }

    @ViewBuilder
    private func structureFooterControls(state: StructureFooterState) -> some View {
        ControlGroup {
            Button {
                onStructureAdd?()
            } label: {
                Label(state.addLabel, systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .help(state.addLabel)
            .accessibilityLabel(state.addLabel)
            .disabled(!state.canAdd)

            Button {
                onStructureRemove?()
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

    private var showsPaginationControls: Bool {
        if let total = snapshot.pagination.totalRowCount, total > 0 { return true }
        return isPagedWithUnknownTotal
    }

    private var isPagedWithUnknownTotal: Bool {
        let pagination = snapshot.pagination
        return pagination.currentPage > 1 || snapshot.rowCount >= pagination.pageSize
    }

    private var rowInfoText: String {
        let loadedCount = snapshot.rowCount
        let selectedCount = selectedRowIndices.count
        let pagination = snapshot.pagination
        let total = pagination.totalRowCount

        if selectedCount > 0 {
            if selectedCount == loadedCount {
                return String(format: String(localized: "All %d rows selected"), loadedCount)
            } else {
                return String(format: String(localized: "%d of %d rows selected"), selectedCount, loadedCount)
            }
        } else if snapshot.tabType == .query && pagination.hasMoreRows {
            let formattedCount = loadedCount.formatted(.number.grouping(.automatic))
            return String(format: String(localized: "Showing %@ rows"), formattedCount)
        } else if snapshot.tabType == .table, let total = total, total > 0 {
            let formattedTotal = total.formatted(.number.grouping(.automatic))
            let prefix = pagination.isApproximateRowCount ? "~" : ""

            return String(format: String(localized: "%d-%d of %@%@ rows"), pagination.rangeStart, pagination.rangeEnd, prefix, formattedTotal)
        } else if snapshot.tabType == .table, isPagedWithUnknownTotal {
            let rangeEnd = pagination.currentOffset + loadedCount
            return String(format: String(localized: "%d-%d of ? rows"), pagination.rangeStart, rangeEnd)
        } else if loadedCount > 0 {
            let formattedCount = loadedCount.formatted(.number.grouping(.automatic))
            return String(format: String(localized: "%@ rows"), formattedCount)
        } else {
            return String(localized: "No rows")
        }
    }
}
