//
//  ResultChartView.swift
//  TablePro
//

import SwiftUI

struct ResultChartProjectionKey: Hashable {
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let xColumn: ResultChartColumnID?
    let yColumn: ResultChartColumnID?
    let seriesColumn: ResultChartColumnID?
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
        xColumn = resolved?.xColumn?.id
        yColumn = resolved?.yColumn.id
        seriesColumn = resolved?.seriesColumn?.id
        self.isUnlocked = isUnlocked
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

    /// Every state the pane can be in has a branch below, so there is no combination that renders
    /// nothing. Projection is cancellable but cannot otherwise fail, which its signature enforces.
    /// A loaded projection carries the key it was built for, so the two cannot disagree.
    private enum LoadState: Equatable {
        case loading
        case loaded(ResultChartProjection, key: ResultChartProjectionKey)
    }

    @State private var state: LoadState = .loading

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

    var body: some View {
        Group {
            if isUnlocked {
                VStack(spacing: 0) {
                    ResultChartToolbar(
                        configuration: $configuration,
                        columns: columns,
                        resolved: resolved,
                        projection: loadedProjection
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

    private var loadedProjection: ResultChartProjection? {
        guard case .loaded(let projection, _) = state else { return nil }
        return projection
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
        } else {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Building chart"))
            case .loaded(let projection, _) where projection.points.isEmpty:
                UnavailableStateView(
                    String(localized: "No Chartable Rows"),
                    systemImage: "chart.bar.xaxis",
                    description: Text(String(localized: "The selected axes contain only null, binary, or invalid values."))
                )
            case .loaded(let projection, _):
                ResultChartCanvas(projection: projection, chartType: configuration.chartType)
                    .id(projectionKey)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    /// A connection switch re-parents the pane and SwiftUI re-runs `task(id:)` with an unchanged
    /// key, so a projection already built for that key is kept rather than blanked and rebuilt.
    /// A cancelled projection commits nothing; the replacement task, or the next appearance, owns
    /// the state from its first line.
    private func rebuild(for expectedKey: ResultChartProjectionKey) async {
        if case .loaded(_, let key) = state, key == expectedKey { return }
        guard expectedKey.isUnlocked, let configuration = resolved else { return }
        state = .loading
        guard let output = try? await ResultChartProjector.shared.project(
            tableRows: tableRows,
            configuration: configuration
        ) else {
            return
        }
        guard !Task.isCancelled, projectionKey == expectedKey else { return }
        state = .loaded(output, key: expectedKey)
    }
}
