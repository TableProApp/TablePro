import SwiftUI

struct TableHealthView: View {
    @ObservedObject var viewModel: TableHealthViewModel
    @ObservedObject var coordinator: MainContentCoordinator

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if viewModel.isSupported {
                    toolbar
                }
            }
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
        } else if let report = viewModel.report {
            VSplitView {
                findingsList(report)
                    .frame(minHeight: 160)
                detailPane
                    .frame(minHeight: 120, idealHeight: 180)
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

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let report = viewModel.report {
                    Text(String(format: String(localized: "%lld findings"), report.findingCount))
                        .font(.callout)
                        .monospacedDigit()
                }
                if let error = viewModel.loadError, viewModel.report != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help(error)
                        .accessibilityLabel(error)
                }

                Spacer(minLength: 8)

                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Refreshing"))
                } else if let date = viewModel.lastRefreshDate {
                    Text(date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(String(localized: "Last updated"))
                }

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Refresh Now"))
                .accessibilityLabel(String(localized: "Refresh Now"))
                .disabled(viewModel.isRefreshing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
        }
        .paneBarBackground()
    }

    // MARK: - Findings

    private func findingsList(_ report: TableHealthReport) -> some View {
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
                    checkRows(check)
                } header: {
                    HStack {
                        Label(check.kind.title, systemImage: check.kind.systemImage)
                        Spacer()
                        if check.error == nil || !check.findings.isEmpty {
                            Text(verbatim: "\(check.findings.count)")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: TableHealthFinding.ID.self) { ids in
            if let finding = finding(in: ids) {
                Button(String(localized: "Open Table")) { openTable(finding) }
                Button(String(localized: "Open Fix in Editor")) { openFix(finding) }
                Button(String(localized: "Copy Fix SQL")) { copyFix(finding) }
            }
        } primaryAction: { ids in
            if let finding = finding(in: ids) { openTable(finding) }
        }
    }

    @ViewBuilder
    private func checkRows(_ check: TableHealthCheckResult) -> some View {
        if let error = check.error {
            Label {
                Text(verbatim: error)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if check.findings.isEmpty {
            Text("No findings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !check.findings.isEmpty {
            ForEach(check.findings) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.qualifiedName(finding))
                    Text(verbatim: finding.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
                .tag(finding.id)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let finding = viewModel.selectedFinding {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: Self.qualifiedName(finding))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(String(localized: "Open Table")) { openTable(finding) }
                    Button(String(localized: "Copy")) { copyFix(finding) }
                    Button(String(localized: "Open in Editor")) { openFix(finding) }
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

    // MARK: - Actions

    private var schemaNamesDatabase: Bool {
        viewModel.provider?.schemaNamesDatabase ?? false
    }

    private func finding(in ids: Set<TableHealthFinding.ID>) -> TableHealthFinding? {
        guard ids.count == 1, let id = ids.first, let report = viewModel.report else { return nil }
        return report.checks.lazy.flatMap(\.findings).first { $0.id == id }
    }

    private func openTable(_ finding: TableHealthFinding) {
        coordinator.openTableHealthFinding(finding, schemaNamesDatabase: schemaNamesDatabase)
    }

    private func openFix(_ finding: TableHealthFinding) {
        coordinator.openTableHealthFix(finding, schemaNamesDatabase: schemaNamesDatabase)
    }

    private func copyFix(_ finding: TableHealthFinding) {
        ClipboardService.shared.writeText(finding.fixSQL)
    }

    static func qualifiedName(_ finding: TableHealthFinding) -> String {
        finding.schema.isEmpty ? finding.table : "\(finding.schema).\(finding.table)"
    }
}
