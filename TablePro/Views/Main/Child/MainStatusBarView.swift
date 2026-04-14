//
//  MainStatusBarView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 24/12/25.
//

import SwiftUI

/// Status bar at the bottom of the results section
struct MainStatusBarView: View {
    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    let tab: QueryTab?
    let filterStateManager: FilterStateManager
    let columnVisibilityManager: ColumnVisibilityManager
    let allColumns: [String]
    let selectedRowIndices: Set<Int>
    @Binding var showStructure: Bool

    @State private var showColumnPopover = false

    // Pagination callbacks
    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onLimitChange: (Int) -> Void
    let onOffsetChange: (Int) -> Void
    let onPaginationGo: () -> Void

    var body: some View {
        HStack {
            // Left: Data/Structure toggle for table tabs
            if let tab = tab, tab.tabType == .table, tab.tableName != nil {
                Picker(String(localized: "View Mode"), selection: $showStructure) {
                    Label("Data", systemImage: "tablecells").tag(false)
                    Label("Structure", systemImage: "list.bullet.rectangle").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
                .controlSize(.small)
            }

            Spacer()

            // Center: Row info (selection or pagination summary) and status message
            if let tab = tab, !tab.resultRows.isEmpty {
                HStack(spacing: 6) {
                    Text(rowInfoText(for: tab))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let statusMessage = tab.statusMessage {
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
                if let tab = tab, !tab.resultColumns.isEmpty {
                    Button {
                        showColumnPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: columnVisibilityManager.hasHiddenColumns
                                    ? "eye.slash.circle.fill"
                                    : "eye.circle")
                            Text("Columns")
                            if columnVisibilityManager.hasHiddenColumns {
                                Text("(\(columnVisibilityManager.hiddenCount) hidden)")
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
                if let tab = tab, tab.tabType == .table, tab.tableName != nil {
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
                if let tab = tab, tab.tabType == .table, tab.tableName != nil,
                   let total = tab.pagination.totalRowCount, total > 0 {
                    PaginationControlsView(
                        pagination: tab.pagination,
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: tab?.id) { _, _ in
            showColumnPopover = false
        }
    }

    /// Generate row info text based on selection and pagination state
    private func rowInfoText(for tab: QueryTab) -> String {
        let loadedCount = tab.resultRows.count
        let selectedCount = selectedRowIndices.count
        let pagination = tab.pagination
        let total = pagination.totalRowCount

        if selectedCount > 0 {
            // Selection mode: "5 of 200 rows selected"
            if selectedCount == loadedCount {
                return String(format: String(localized: "All %d rows selected"), loadedCount)
            } else {
                return String(format: String(localized: "%d of %d rows selected"), selectedCount, loadedCount)
            }
        } else if tab.tabType == .table, let total = total, total > 0 {
            // Pagination mode (table tabs only): "201-400 of 5,000 rows"
            let formattedTotal = Self.decimalFormatter.string(from: NSNumber(value: total)) ?? "\(total)"
            let prefix = pagination.isApproximateRowCount ? "~" : ""

            return String(format: String(localized: "%d-%d of %@%@ rows"), pagination.rangeStart, pagination.rangeEnd, prefix, formattedTotal)
        } else if loadedCount > 0 {
            let formattedCount = Self.decimalFormatter.string(from: NSNumber(value: loadedCount)) ?? "\(loadedCount)"
            return String(format: String(localized: "%@ rows"), formattedCount)
        } else {
            return String(localized: "No rows")
        }
    }
}
