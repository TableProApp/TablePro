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

    init(tab: QueryTab?, buffer: RowBuffer?) {
        self.tabId = tab?.id
        self.tabType = tab?.tabType
        self.hasRows = !(buffer?.rows.isEmpty ?? true)
        self.hasColumns = !(buffer?.columns.isEmpty ?? true)
        self.rowCount = buffer?.rows.count ?? 0
        self.hasTableName = tab?.tableContext.tableName != nil
        self.pagination = tab?.pagination ?? PaginationState()
        self.statusMessage = tab?.execution.statusMessage
    }
}

struct MainStatusBarView: View {
    let snapshot: StatusBarSnapshot
    let filterStateManager: FilterStateManager
    let columnVisibilityManager: ColumnVisibilityManager
    let allColumns: [String]
    let selectedRowIndices: Set<Int>
    @Binding var viewMode: ResultsViewMode

    @State private var showColumnPopover = false

    // Pagination callbacks
    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onLimitChange: (Int) -> Void
    let onOffsetChange: (Int) -> Void
    let onPaginationGo: () -> Void

    // Progressive loading callbacks
    var onLoadMore: (() -> Void)?
    var onFetchAll: (() -> Void)?

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

            // Center: Row info (selection or pagination summary) and status message
            if snapshot.hasRows {
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
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Button {
                            onLoadMore?()
                        } label: {
                            Text("Load More")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)

                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Button {
                            onFetchAll?()
                        } label: {
                            Text("Fetch All")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
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

            // Right: Columns, Filters toggle and Pagination controls
            HStack(spacing: 8) {
                // Columns visibility button (works for both table and query tabs)
                if snapshot.hasColumns {
                    Button {
                        showColumnPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: columnVisibilityManager.hasHiddenColumns
                                    ? "eye.slash.circle.fill"
                                    : "eye.circle")
                            Text("Columns")
                            if columnVisibilityManager.hasHiddenColumns {
                                let visible = allColumns.count - columnVisibilityManager.hiddenCount
                                Text("(\(visible)/\(allColumns.count))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .controlSize(.small)
                    .popover(isPresented: $showColumnPopover) {
                        ColumnVisibilityPopover(
                            columns: allColumns,
                            columnVisibilityManager: columnVisibilityManager
                        )
                    }
                }

                // Filters toggle button
                if snapshot.tabType == .table, snapshot.hasTableName {
                    Toggle(isOn: Binding(
                        get: { filterStateManager.isVisible },
                        set: { _ in filterStateManager.toggle() }
                    )) {
                        HStack(spacing: 4) {
                            Image(systemName: filterStateManager.hasAppliedFilters
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle")
                            Text("Filters")
                            if filterStateManager.hasAppliedFilters {
                                Text("(\(filterStateManager.appliedFilters.count))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(String(localized: "Toggle Filters (⇧⌘F)"))
                }

                // Pagination controls for table tabs
                if snapshot.tabType == .table, snapshot.hasTableName,
                   let total = snapshot.pagination.totalRowCount, total > 0 {
                    PaginationControlsView(
                        pagination: snapshot.pagination,
                        onFirst: onFirstPage,
                        onPrevious: onPreviousPage,
                        onNext: onNextPage,
                        onLast: onLastPage,
                        onLimitChange: onLimitChange,
                        onOffsetChange: onOffsetChange,
                        onGo: onPaginationGo
                    )
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

    /// Generate row info text based on selection and pagination state
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
            if let total = total, total > 0 {
                let formattedTotal = total.formatted(.number.grouping(.automatic))
                let prefix = pagination.isApproximateRowCount ? "~" : ""
                return String(format: String(localized: "%@ of %@%@ rows"), formattedCount, prefix, formattedTotal)
            }
            return String(format: String(localized: "%@ rows (more available)"), formattedCount)
        } else if snapshot.tabType == .table, let total = total, total > 0 {
            let formattedTotal = total.formatted(.number.grouping(.automatic))
            let prefix = pagination.isApproximateRowCount ? "~" : ""

            return String(format: String(localized: "%d-%d of %@%@ rows"), pagination.rangeStart, pagination.rangeEnd, prefix, formattedTotal)
        } else if loadedCount > 0 {
            let formattedCount = loadedCount.formatted(.number.grouping(.automatic))
            return String(format: String(localized: "%@ rows"), formattedCount)
        } else {
            return String(localized: "No rows")
        }
    }
}
