//
//  ResultChartView.swift
//  TablePro
//

import SwiftUI

struct ResultChartProjectionKey: Hashable {
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let xColumnIndex: Int?
    let yColumnIndex: Int?
    let seriesColumnIndex: Int?
    let isUnlocked: Bool

    init(
        tabId: UUID,
        resultSetId: UUID,
        dataRevision: Int,
        configuration: ResultChartConfiguration,
        isUnlocked: Bool
    ) {
        self.tabId = tabId
        self.resultSetId = resultSetId
        self.dataRevision = dataRevision
        self.xColumnIndex = configuration.xColumnIndex
        self.yColumnIndex = configuration.yColumnIndex
        self.seriesColumnIndex = configuration.seriesColumnIndex
        self.isUnlocked = isUnlocked
    }
}

struct ResultChartView: View {
    @Bindable var resultSet: ResultSet
    let tableRows: TableRows
    let tabId: UUID
    let dataRevision: Int
    let hasUnloadedRows: Bool
    let isUnlocked: Bool

    @State private var projection: ResultChartProjection?
    @State private var isLoading = false

    private var projectionKey: ResultChartProjectionKey {
        ResultChartProjectionKey(
            tabId: tabId,
            resultSetId: resultSet.id,
            dataRevision: dataRevision,
            configuration: resultSet.chartConfiguration,
            isUnlocked: isUnlocked
        )
    }

    private var columns: [ResultChartColumn] {
        ResultChartColumn.columns(in: tableRows)
    }

    private var resolvedConfiguration: ResultChartConfiguration.Resolved? {
        resultSet.chartConfiguration.resolved(in: columns)
    }

    var body: some View {
        Group {
            if isUnlocked {
                VStack(spacing: 0) {
                    ResultChartToolbar(
                        configuration: configurationBinding,
                        columns: columns,
                        loadedRowCount: tableRows.rows.count,
                        skippedRowCount: projection?.skippedRowCount ?? 0,
                        hasUnloadedRows: hasUnloadedRows
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

    private var configurationBinding: Binding<ResultChartConfiguration> {
        Binding(
            get: { resultSet.chartConfiguration },
            set: { resultSet.chartConfiguration = $0 }
        )
    }

    @ViewBuilder
    private var content: some View {
        if tableRows.rows.isEmpty {
            ContentUnavailableView(
                String(localized: "No Data"),
                systemImage: "chart.bar.xaxis",
                description: Text(String(localized: "Execute a query to chart its loaded rows."))
            )
        } else if resolvedConfiguration == nil {
            ContentUnavailableView(
                String(localized: "Choose Chart Columns"),
                systemImage: "slider.horizontal.3",
                description: Text(String(localized: "Choose a numeric Y column. X can use row numbers or a supported column."))
            )
        } else if isLoading {
            ProgressView()
                .controlSize(.small)
        } else if let projection {
            projectionContent(projection)
        }
    }

    @ViewBuilder
    private func projectionContent(_ projection: ResultChartProjection) -> some View {
        switch projection.issue {
        case .noChartableRows:
            ContentUnavailableView(
                String(localized: "No Chartable Rows"),
                systemImage: "chart.bar.xaxis",
                description: Text(String(localized: "The selected axes contain only null, binary, or invalid numeric values."))
            )
        case .tooManyPoints(let limit):
            ContentUnavailableView(
                String(localized: "Too Many Chart Points"),
                systemImage: "chart.bar.xaxis",
                description: Text(
                    String(
                        format: String(localized: "Charts support up to %d chartable points. Narrow the query or use a smaller page."),
                        limit
                    )
                )
            )
        case .tooManySeries(let limit):
            ContentUnavailableView(
                String(localized: "Too Many Series"),
                systemImage: "square.stack.3d.up",
                description: Text(
                    String(
                        format: String(localized: "Charts support up to %d series. Choose another series column or narrow the query."),
                        limit
                    )
                )
            )
        case .tooManyRows(let limit):
            ContentUnavailableView(
                String(localized: "Too Many Rows to Inspect"),
                systemImage: "chart.bar.xaxis",
                description: Text(
                    String(
                        format: String(localized: "Charts inspect up to %d loaded rows. Narrow the query or use a smaller page."),
                        limit
                    )
                )
            )
        case nil:
            if let configuration = resolvedConfiguration {
                ResultChartCanvas(projection: projection, chartType: configuration.chartType)
                    .padding(20)
            }
        }
    }

    private func rebuild(for expectedKey: ResultChartProjectionKey) async {
        guard expectedKey.isUnlocked, let configuration = resolvedConfiguration else {
            projection = nil
            isLoading = false
            return
        }

        projection = nil
        isLoading = true
        do {
            let output = try await ResultChartProjector.shared.project(
                tableRows: tableRows,
                configuration: configuration
            )
            guard !Task.isCancelled, projectionKey == expectedKey else { return }
            projection = output
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard projectionKey == expectedKey else { return }
            projection = nil
            isLoading = false
        }
    }
}
