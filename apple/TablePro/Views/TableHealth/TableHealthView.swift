import SwiftUI

@MainActor
struct TableHealthActions {
    let openTable: (_ finding: TableHealthFinding, _ database: String) -> Void
    let openFix: (_ finding: TableHealthFinding, _ database: String) -> Void

    func copyFix(_ finding: TableHealthFinding) {
        ClipboardService.shared.writeText(finding.fixSQL)
    }
}

struct TableHealthView: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let actions: TableHealthActions

    // A VStack, not safeAreaInset: the inset does not reach a List hosted inside the split view.
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSupported {
                header
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.isSupported {
            UnavailableStateView(
                String(localized: "Table Health Not Available"),
                systemImage: "stethoscope",
                description: Text("Table health is available for PostgreSQL, MySQL and MariaDB.")
            )
        } else if viewModel.report != nil {
            AutosavingSplitView(
                autosaveName: "com.TablePro.tableHealth.findingsDetail",
                isVertical: false,
                primaryMinimum: 160,
                secondaryMinimum: 150,
                primaryHoldingPriority: .splitPaneFlexible
            ) {
                TableHealthFindingsList(viewModel: viewModel, actions: actions)
            } secondary: {
                TableHealthDetailPane(viewModel: viewModel, actions: actions)
            }
        } else if let error = viewModel.loadError {
            UnavailableStateView {
                Label(String(localized: "Could Not Read Table Health"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await viewModel.refresh() }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let report = viewModel.report {
                    Text(verbatim: report.database)
                        .font(.callout.weight(.semibold))
                    Text("^[\(report.findingCount) finding](inflect: true)")
                        .font(.callout)
                        .monospacedDigit()
                    if let error = viewModel.loadError {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .help(error)
                            .accessibilityLabel(error)
                    }
                }

                Spacer(minLength: 8)

                PaneRefreshControls(
                    isRefreshing: viewModel.isRefreshing,
                    lastRefreshDate: viewModel.lastRefreshDate,
                    accessibilityIdentifier: "table-health-refresh-button"
                ) {
                    Task { await viewModel.refresh() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
        }
        .paneBarBackground()
    }
}

private struct TableHealthFindingsList: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let actions: TableHealthActions

    var body: some View {
        if let report = viewModel.report {
            List(selection: $viewModel.selectedFindingId) {
                if let note = report.statisticsNote {
                    Section {
                        Label(note, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(report.checks) { check in
                    Section {
                        rows(check)
                    } header: {
                        HStack {
                            Label(check.kind.title, systemImage: check.kind.systemImage)
                            Spacer()
                            if check.outcome == .completed || !check.findings.isEmpty {
                                Text(verbatim: "\(check.findings.count)")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: TableHealthFinding.ID.self) { ids in
                if let finding = finding(in: ids, of: report) {
                    Button(String(localized: "Open Table")) { actions.openTable(finding, report.database) }
                    Button(String(localized: "Open Fix in Editor")) { actions.openFix(finding, report.database) }
                    Button(String(localized: "Copy Fix SQL")) { actions.copyFix(finding) }
                }
            } primaryAction: { ids in
                if let finding = finding(in: ids, of: report) {
                    actions.openTable(finding, report.database)
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ check: TableHealthCheckResult) -> some View {
        switch check.outcome {
        case .failed(let message):
            status(message, systemImage: "exclamationmark.triangle")
        case .skipped(let reason):
            status(reason, systemImage: "info.circle")
        case .completed:
            if check.findings.isEmpty {
                Text("No findings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(check.findings) { finding in
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: finding.qualifiedTable)
                Text(verbatim: finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
            .tag(finding.id)
        }
    }

    private func status(_ message: String, systemImage: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func finding(in ids: Set<TableHealthFinding.ID>, of report: TableHealthReport) -> TableHealthFinding? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return report.finding(id: id)
    }
}

private struct TableHealthDetailPane: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let actions: TableHealthActions

    var body: some View {
        if let finding = viewModel.selectedFinding, let database = viewModel.report?.database {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: finding.qualifiedTable)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(String(localized: "Open Table")) { actions.openTable(finding, database) }
                    Button(String(localized: "Copy")) { actions.copyFix(finding) }
                    Button(String(localized: "Open in Editor")) { actions.openFix(finding, database) }
                }
                ScrollView {
                    Text(verbatim: finding.fixSQL)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("This SQL is a preview. TablePro never runs it; review it in the editor and run it yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        } else {
            Text("Select a finding to preview the SQL that fixes it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
