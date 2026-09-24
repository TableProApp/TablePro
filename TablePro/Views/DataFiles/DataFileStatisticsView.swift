//
//  DataFileStatisticsView.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProTabular

@MainActor
final class DataFileStatisticsModel: ObservableObject {
    enum State: Equatable {
        case computing(Double)
        case ready(TabularColumnSummary)
        case failed(String)
    }

    static let collapsedValueCount = 10

    @Published private(set) var state: State = .computing(0)
    @Published var showsAllValues = false
    let request: DataFileStatisticsRequest
    private var task: Task<Void, Never>?

    init(request: DataFileStatisticsRequest) {
        self.request = request
    }

    func start() {
        task?.cancel()
        state = .computing(0)
        let request = request
        let reportProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .computing = self.state else { return }
                self.state = .computing(fraction)
            }
        }
        task = Task { [weak self] in
            do {
                let summary = try await request.summarize(progress: reportProgress)
                self?.state = .ready(summary)
            } catch {
                guard !error.isDataFileCancellation else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

struct DataFileStatisticsView: View {
    @ObservedObject var model: DataFileStatisticsModel
    let onPickValue: (TabularValueCount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.state {
            case .computing(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(String(localized: "Counting values…"))
                Text(String(localized: "Counting values…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
            case .ready(let summary):
                summaryGrid(summary)
                Divider()
                topValues(summary)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.start() }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.request.columnName)
                .font(.headline)
                .lineLimit(1)
            Text(model.request.isFiltered
                ? String(format: String(localized: "%@ visible rows"), model.request.keys.count.formatted())
                : String(format: String(localized: "All %@ rows"), model.request.keys.count.formatted()))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryGrid(_ summary: TabularColumnSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metric(String(localized: "Count"), summary.rowCount.formatted())
            metric(String(localized: "Empty"), summary.emptyCount.formatted())
            metric(String(localized: "Distinct"), summary.distinctCount.formatted())
            if let numeric = summary.numeric {
                metric(String(localized: "Minimum"), numeric.minimum.formatted())
                metric(String(localized: "Maximum"), numeric.maximum.formatted())
                metric(String(localized: "Sum"), numeric.sum.formatted())
                metric(String(localized: "Mean"), numeric.mean.formatted())
                metric(String(localized: "Median"), numeric.median.formatted())
            }
            if summary.nonNumericCount > 0 {
                metric(String(localized: "Not a number"), summary.nonNumericCount.formatted())
            }
            if let earliest = summary.earliestDate, let latest = summary.latestDate {
                metric(String(localized: "Earliest"), earliest)
                metric(String(localized: "Latest"), latest)
            }
            if let shortest = summary.shortestLength, let longest = summary.longestLength {
                metric(String(localized: "Length"), String(format: String(localized: "%@ to %@ characters"), shortest.formatted(), longest.formatted()))
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func topValues(_ summary: TabularColumnSummary) -> some View {
        let values = model.showsAllValues ? summary.topValues : Array(summary.topValues.prefix(DataFileStatisticsModel.collapsedValueCount))
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Top Values"))
                .font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        valueRow(value, total: max(1, summary.rowCount))
                    }
                }
            }
            .frame(maxHeight: model.showsAllValues ? 260 : nil)
            if !model.showsAllValues, summary.topValues.count > DataFileStatisticsModel.collapsedValueCount {
                Button(String(format: String(localized: "Show All (%@)"), summary.topValues.count.formatted())) {
                    model.showsAllValues = true
                }
                .buttonStyle(.link)
            }
        }
    }

    private func valueRow(_ value: TabularValueCount, total: Int) -> some View {
        Button {
            onPickValue(value)
        } label: {
            HStack(spacing: 8) {
                Text(value.isEmpty ? String(localized: "(empty)") : value.value)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                Spacer(minLength: 8)
                Text(value.count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text((Double(value.count) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Filter rows with this value"))
        .accessibilityIdentifier("data-file-statistics-value")
        .accessibilityLabel(String(
            format: String(localized: "%@, %@ rows"),
            value.isEmpty ? String(localized: "(empty)") : value.value,
            value.count.formatted()
        ))
    }
}

extension DataFileSplitViewController {
    func showStatistics(for id: TabularColumnID) {
        guard let request = controller.statisticsRequest(for: id) else { return }
        statisticsPopover?.close()
        let model = DataFileStatisticsModel(request: request)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DataFileStatisticsView(model: model) { [weak self, weak popover] value in
            popover?.close()
            self?.controller.addEqualsFilter(column: id, value: value)
        })
        statisticsPopover = popover
        let anchor = headerAnchor(for: id)
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
    }

    private func headerAnchor(for id: TabularColumnID) -> (rect: NSRect, view: NSView) {
        guard let coordinator = controller.gridCoordinator, let tableView = coordinator.tableView,
              let headerView = tableView.headerView, let dataIndex = controller.columnNames.index(of: id),
              let tableColumnIndex = tableView.tableColumns.firstIndex(where: { coordinator.dataColumnIndex(from: $0.identifier) == dataIndex })
        else {
            return (view.bounds.insetBy(dx: view.bounds.width / 2 - 1, dy: view.bounds.height / 2 - 1), view)
        }
        return (headerView.headerRect(ofColumn: tableColumnIndex), headerView)
    }
}
