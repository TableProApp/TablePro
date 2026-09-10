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
    private enum LoadState: Equatable {
        case loading
        case loaded(ResultChartProjection)
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
        guard case .loaded(let projection) = state else { return nil }
        return projection
    }

    @ViewBuilder
    private var content: some View {
        if tableRows.rows.isEmpty {
            ContentUnavailableView(
                String(localized: "No Data"),
                systemImage: "chart.bar.xaxis",
                description: Text(String(localized: "Execute a query to chart its loaded rows."))
            )
        } else if resolved == nil {
            ContentUnavailableView(
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
            case .loaded(let projection) where projection.points.isEmpty:
                ContentUnavailableView(
                    String(localized: "No Chartable Rows"),
                    systemImage: "chart.bar.xaxis",
                    description: Text(String(localized: "The selected axes contain only null, binary, or invalid values."))
                )
            case .loaded(let projection):
                ResultChartCanvas(projection: projection, chartType: configuration.chartType)
                    .id(projectionKey)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    /// A cancelled projection leaves the state alone: `task(id:)` cancels only to start a
    /// replacement, and that replacement owns the state from its first line.
    private func rebuild(for expectedKey: ResultChartProjectionKey) async {
        guard expectedKey.isUnlocked, let configuration = resolved else { return }
        state = .loading
        guard let output = try? await ResultChartProjector.shared.project(
            tableRows: tableRows,
            configuration: configuration
        ) else {
            return
        }
        guard projectionKey == expectedKey else { return }
        state = .loaded(output)
    }
}
