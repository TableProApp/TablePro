//
//  ResultChartView.swift
//  TablePro
//

import SwiftUI

struct ResultChartProjectionKey: ResultPaneProjectionKey {
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let columns: ResultChartConfiguration.ColumnIDs?
    let isUnlocked: Bool

    init(
        tabId: UUID,
        resultSetId: UUID,
        dataRevision: Int,
        resolved: ResultChartConfiguration.Resolved?,
        isUnlocked: Bool
    ) {
        self.tabId = tabId
        self.resultSetId = resultSetId
        self.dataRevision = dataRevision
        columns = resolved?.columnIDs
        self.isUnlocked = isUnlocked
    }

    struct Subject: Hashable {
        let tabId: UUID
        let columns: ResultChartConfiguration.ColumnIDs?
        let isUnlocked: Bool
    }

    var subject: Subject {
        Subject(tabId: tabId, columns: columns, isUnlocked: isUnlocked)
    }
}

struct ResultChartView: View {
    @Binding var configuration: ResultChartConfiguration
    let tableRows: TableRows
    let primaryKeyColumns: Set<String>
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let isUnlocked: Bool

    @State private var state = ResultPaneProjectionState<ResultChartProjection, ResultChartProjectionKey>()

    private var columns: [ResultChartColumn] {
        ResultChartColumn.columns(in: tableRows, primaryKeyColumns: primaryKeyColumns)
    }

    private var resolved: ResultChartConfiguration.Resolved? {
        configuration.resolved(in: columns)
    }

    private var projectionKey: ResultChartProjectionKey {
        ResultChartProjectionKey(
            tabId: tabId,
            resultSetId: resultSetId,
            dataRevision: dataRevision,
            resolved: resolved,
            isUnlocked: isUnlocked
        )
    }

    /// Nothing is shown for a result with no numeric column, so its notices cannot come from the
    /// last result that had one.
    private var shownProjection: ResultChartProjection? {
        guard resolved != nil else { return nil }
        return state.projection(for: projectionKey)
    }

    var body: some View {
        Group {
            if isUnlocked {
                VStack(spacing: 0) {
                    ResultChartToolbar(
                        configuration: $configuration,
                        columns: columns,
                        resolved: resolved,
                        projection: shownProjection
                    )
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Color.clear
            }
        }
        .requiresPro(.resultCharts)
        .task(id: projectionKey) {
            await rebuild(for: projectionKey)
        }
    }

    @ViewBuilder
    private var content: some View {
        if tableRows.rows.isEmpty {
            UnavailableStateView(
                String(localized: "No Data"),
                systemImage: "chart.bar.xaxis",
                description: Text(String(localized: "Execute a query to chart its loaded rows."))
            )
        } else if resolved == nil {
            UnavailableStateView(
                String(localized: "No Numeric Column"),
                systemImage: "slider.horizontal.3",
                description: Text(String(localized: "Charts need a numeric column for the Y axis. This result has none."))
            )
        } else if let projection = shownProjection {
            if projection.points.isEmpty {
                UnavailableStateView(
                    String(localized: "No Chartable Rows"),
                    systemImage: "chart.bar.xaxis",
                    description: Text(String(localized: "The selected axes contain only null, binary, or invalid values."))
                )
            } else {
                chart(projection)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Building chart"))
        }
    }

    /// A new projection resets the charts' hover through `.id`, keyed by the key it was built for,
    /// so the reset lands with the new drawing rather than while the old one is still up.
    @ViewBuilder
    private func chart(_ projection: ResultChartProjection) -> some View {
        if projection.isFaceted {
            ResultChartFacetGrid(
                projection: projection,
                chartType: configuration.chartType,
                revision: AnyHashable(state.key)
            )
        } else {
            ResultChartCanvas(projection: projection, chartType: configuration.chartType)
                .id(state.key)
        }
    }

    /// A connection switch re-parents the pane and SwiftUI re-runs `task(id:)` with an unchanged
    /// key, so a projection already built for that key is kept rather than rebuilt. `task(id:)`
    /// cancels the previous task when the key changes, and a cancelled projection commits nothing.
    private func rebuild(for expectedKey: ResultChartProjectionKey) async {
        if state.isCurrent(for: expectedKey) { return }
        guard expectedKey.isUnlocked, let configuration = resolved else { return }
        guard let output = try? await ResultChartProjector.shared.project(
            tableRows: tableRows,
            configuration: configuration
        ) else {
            return
        }
        guard !Task.isCancelled else { return }
        state.commit(output, for: expectedKey)
    }
}
